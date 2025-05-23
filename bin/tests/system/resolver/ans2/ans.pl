#!/usr/bin/perl

# Copyright (C) Internet Systems Consortium, Inc. ("ISC")
#
# SPDX-License-Identifier: MPL-2.0
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0.  If a copy of the MPL was not distributed with this
# file, you can obtain one at https://mozilla.org/MPL/2.0/.
#
# See the COPYRIGHT file distributed with this work for additional
# information regarding copyright ownership.

#
# Ad hoc name server
#

use IO::File;
use IO::Socket;
use Net::DNS;
use Net::DNS::Packet;

print "Using Net::DNS $Net::DNS::VERSION\n";

my $localport = int($ENV{'PORT'});
if (!$localport) { $localport = 5300; }

my $sock = IO::Socket::INET->new(LocalAddr => "10.53.0.2",
   LocalPort => $localport, Proto => "udp") or die "$!";

my $pidf = new IO::File "ans.pid", "w" or die "cannot open pid file: $!";
print $pidf "$$\n" or die "cannot write pid file: $!";
$pidf->close or die "cannot close pid file: $!";
sub rmpid { unlink "ans.pid"; exit 1; };

$SIG{INT} = \&rmpid;
$SIG{TERM} = \&rmpid;

for (;;) {
	$sock->recv($buf, 512);

	print "**** request from " , $sock->peerhost, " port ", $sock->peerport, "\n";

	my $packet;

	if ($Net::DNS::VERSION > 0.68) {
		$packet = new Net::DNS::Packet(\$buf, 0);
		$@ and die $@;
	} else {
		my $err;
		($packet, $err) = new Net::DNS::Packet(\$buf, 0);
		$err and die $err;
	}

	print "REQUEST:\n";
	$packet->print;

	$packet->header->qr(1);

	my @questions = $packet->question;
	my $qname = $questions[0]->qname;
	my $qtype = $questions[0]->qtype;

	if ($qname eq "com" && $qtype eq "NS") {
		$packet->header->aa(1);
		$packet->push("answer", new Net::DNS::RR("com 300 NS a.root-servers.nil."));
	} elsif ($qname eq "example.com" && $qtype eq "NS") {
		$packet->header->aa(1);
		$packet->push("answer", new Net::DNS::RR("example.com 300 NS a.root-servers.nil."));
	} elsif ($qname eq "cname1.example.com") {
		# Data for the "cname + other data / 1" test
		$packet->push("answer", new Net::DNS::RR("cname1.example.com 300 CNAME cname1.example.com"));
		$packet->push("answer", new Net::DNS::RR("cname1.example.com 300 A 1.2.3.4"));
	} elsif ($qname eq "cname2.example.com") {
		# Data for the "cname + other data / 2" test: same RRs in opposite order
		$packet->push("answer", new Net::DNS::RR("cname2.example.com 300 A 1.2.3.4"));
		$packet->push("answer", new Net::DNS::RR("cname2.example.com 300 CNAME cname2.example.com"));
	} elsif ($qname =~ /redirect\.com/) {
		$packet->push("authority", new Net::DNS::RR("redirect.com 300 NS ns.redirect.com"));
		$packet->push("additional", new Net::DNS::RR("ns.redirect.com 300 A 10.53.0.6"));
	} elsif ($qname =~ /\.tld1/) {
		$packet->push("authority", new Net::DNS::RR("tld1 300 NS ns.tld1"));
		$packet->push("additional", new Net::DNS::RR("ns.tld1 300 A 10.53.0.6"));
	} elsif ($qname =~ /\.tld2/) {
		$packet->push("authority", new Net::DNS::RR("tld2 300 NS ns.tld2"));
		$packet->push("additional", new Net::DNS::RR("ns.tld2 300 A 10.53.0.7"));
	} elsif ($qname eq "org" && $qtype eq "NS") {
		$packet->header->aa(1);
		$packet->push("answer", new Net::DNS::RR("org 300 NS a.root-servers.nil."));
	} elsif ($qname eq "example.org" && $qtype eq "NS") {
		$packet->header->aa(1);
		$packet->push("answer", new Net::DNS::RR("example.org 300 NS a.root-servers.nil."));
	} elsif (($qname eq "baddname.example.org" || $qname eq "gooddname.example.org") && $qtype eq "NS") {
		$packet->header->aa(1);
		$packet->push("answer", new Net::DNS::RR("example.org 300 NS a.root-servers.nil."));
	} elsif ($qname eq "www.example.org" ||
		 $qname eq "badcname.example.org" ||
		 $qname eq "goodcname.example.org" ||
		 $qname eq "foo.baddname.example.org" ||
		 $qname eq "foo.gooddname.example.org") {
		# Data for address/alias filtering.
		$packet->header->aa(1);
		if ($qtype eq "A") {
			$packet->push("answer",
				      new Net::DNS::RR($qname .
						       " 300 A 192.0.2.1"));
		} elsif ($qtype eq "AAAA") {
			$packet->push("answer",
				      new Net::DNS::RR($qname .
						" 300 AAAA 2001:db8:beef::1"));
		}
	} elsif ($qname eq "net" && $qtype eq "NS") {
		$packet->header->aa(1);
		$packet->push("answer", new Net::DNS::RR("net 300 NS a.root-servers.nil."));
	} elsif ($qname eq "noresponse.exampleudp.net") {
		next;
	} elsif ($qname =~ /example\.net/) {
		$packet->push("authority", new Net::DNS::RR("example.net 300 NS ns.example.net"));
		$packet->push("additional", new Net::DNS::RR("ns.example.net 300 A 10.53.0.3"));
	} elsif ($qname =~ /exampleudp\.net/) {
		$packet->push("authority", new Net::DNS::RR("exampleudp.net 300 NS ns.exampleudp.net"));
		$packet->push("additional", new Net::DNS::RR("ns.exampleudp.net 300 A 10.53.0.2"));
	} elsif ($qname =~ /lame\.example\.org/) {
		$packet->header->ad(0);
		$packet->header->aa(0);
		$packet->push("authority", new Net::DNS::RR("lame.example.org 300 NS ns.lame.example.org"));
		$packet->push("additional", new Net::DNS::RR("ns.lame.example.org 300 A 10.53.0.3"));
	} elsif ($qname =~ /sub\.example\.org/) {
		# Data for CNAME/DNAME filtering.  The final answers are
		# expected to be accepted regardless of the filter setting.
		$packet->push("authority", new Net::DNS::RR("sub.example.org 300 NS ns.sub.example.org"));
		$packet->push("additional", new Net::DNS::RR("ns.sub.example.org 300 A 10.53.0.3"));
	} elsif ($qname =~ /glue-in-answer\.example\.org/) {
		$packet->push("answer", new Net::DNS::RR("ns.glue-in-answer.example.org 300 A 10.53.0.3"));
		$packet->push("authority", new Net::DNS::RR("glue-in-answer.example.org 300 NS ns.glue-in-answer.example.org"));
		$packet->push("additional", new Net::DNS::RR("ns.glue-in-answer.example.org 300 A 10.53.0.3"));
	} elsif ($qname =~ /\.broken/ || $qname =~ /^broken/) {
		# Delegation to broken TLD.
		$packet->push("authority", new Net::DNS::RR("broken 300 NS ns.broken"));
		$packet->push("additional", new Net::DNS::RR("ns.broken 300 A 10.53.0.4"));
	} elsif ($qname =~ /\.partial-formerr/) {
		$packet->header->rcode("FORMERR");
	} elsif ($qname eq "gl6412") {
		if ($qtype eq "SOA") {
			$packet->push("answer",
			      new Net::DNS::RR($qname . " 300 SOA . . 0 0 0 0 0"));
		} elsif ($qtype eq "NS") {
			$packet->push("answer",
			      new Net::DNS::RR($qname . " 300 NS ns2" . $qname));
			$packet->push("answer",
			      new Net::DNS::RR($qname . " 300 NS ns3" . $qname));
		} else {
			$packet->push("authority",
			      new Net::DNS::RR($qname . " 300 SOA . . 0 0 0 0 0"));
		}
	} elsif ($qname eq "a.gl6412" || $qname eq "a.a.gl6412") {
		$packet->push("authority",
			      new Net::DNS::RR($qname . " 300 SOA . . 0 0 0 0 0"));
	} elsif ($qname eq "ns2.gl6412") {
		if ($qtype eq "A") {
			$packet->push("answer",
				      new Net::DNS::RR($qname . " 300 A 10.53.0.2"));
		} else {
			$packet->push("authority",
				      new Net::DNS::RR($qname . " 300 SOA . . 0 0 0 0 0"));
		}
	} elsif ($qname eq "ns3.gl6412") {
		if ($qtype eq "A") {
			$packet->push("answer",
				      new Net::DNS::RR($qname . " 300 A 10.53.0.3"));
		} else {
			$packet->push("authority",
				      new Net::DNS::RR($qname . " 300 SOA . . 0 0 0 0 0"));
		}
	} elsif ($qname eq "zoneversion") {
		$packet->push("authority", new Net::DNS::RR(". 300 SOA . . 0 0 0 0 0"));
		if ($Net::DNS::VERSION >= 1.49) {
			$packet->edns->option('ZONEVERSION' => [0, 1, '01022304'] )
		} elsif ($Net::DNS::VERSION >= 1.35) {
			$packet->edns->option('19' => {'BASE16' => '000101022304'} )
		} else {
			$packet->edns->option('19' => pack 'H*', '000101022304')
		}
	} else {
		# Data for the "bogus referrals" test
		$packet->push("authority", new Net::DNS::RR("below.www.example.com 300 NS ns.below.www.example.com"));
		$packet->push("additional", new Net::DNS::RR("ns.below.www.example.com 300 A 10.53.0.3"));
	}

	$sock->send($packet->data);

	print "RESPONSE:\n";
	$packet->print;
	print "\n";
}
