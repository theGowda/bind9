/*
 * Copyright (C) Internet Systems Consortium, Inc. ("ISC")
 *
 * SPDX-License-Identifier: MPL-2.0
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, you can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * See the COPYRIGHT file distributed with this work for additional
 * information regarding copyright ownership.
 */

/*! \file */

#include <inttypes.h>
#include <string.h>

#include <isc/atomic.h>
#include <isc/buffer.h>
#include <isc/magic.h>
#include <isc/mem.h>
#include <isc/refcount.h>
#include <isc/stats.h>
#include <isc/util.h>

#define ISC_STATS_MAGIC	   ISC_MAGIC('S', 't', 'a', 't')
#define ISC_STATS_VALID(x) ISC_MAGIC_VALID(x, ISC_STATS_MAGIC)

/*
 * Statistics are counted with an atomic int_fast64_t but exported to functions
 * taking uint64_t (isc_stats_dumper_t). A 128-bit native and fast architecture
 * doesn't exist in reality so these two are the same thing in practise.
 * However, a silent truncation happening silently in the future is still not
 * acceptable.
 */
STATIC_ASSERT(sizeof(isc_statscounter_t) <= sizeof(uint64_t),
	      "Exported statistics must fit into the statistic counter size");

struct isc_stats {
	unsigned int magic;
	isc_mem_t *mctx;
	isc_refcount_t references;
	int ncounters;
	isc_atomic_statscounter_t *counters;
};

void
isc_stats_attach(isc_stats_t *stats, isc_stats_t **statsp) {
	REQUIRE(ISC_STATS_VALID(stats));
	REQUIRE(statsp != NULL && *statsp == NULL);

	isc_refcount_increment(&stats->references);
	*statsp = stats;
}

void
isc_stats_detach(isc_stats_t **statsp) {
	isc_stats_t *stats;

	REQUIRE(statsp != NULL && ISC_STATS_VALID(*statsp));

	stats = *statsp;
	*statsp = NULL;

	if (isc_refcount_decrement(&stats->references) == 1) {
		isc_refcount_destroy(&stats->references);
		isc_mem_cput(stats->mctx, stats->counters, stats->ncounters,
			     sizeof(isc_atomic_statscounter_t));
		isc_mem_putanddetach(&stats->mctx, stats, sizeof(*stats));
	}
}

int
isc_stats_ncounters(isc_stats_t *stats) {
	REQUIRE(ISC_STATS_VALID(stats));

	return stats->ncounters;
}

void
isc_stats_create(isc_mem_t *mctx, isc_stats_t **statsp, int ncounters) {
	REQUIRE(statsp != NULL && *statsp == NULL);

	isc_stats_t *stats = isc_mem_get(mctx, sizeof(*stats));
	size_t counters_alloc_size = sizeof(isc_atomic_statscounter_t) *
				     ncounters;
	stats->counters = isc_mem_get(mctx, counters_alloc_size);
	isc_refcount_init(&stats->references, 1);
	for (int i = 0; i < ncounters; i++) {
		atomic_init(&stats->counters[i], 0);
	}
	stats->mctx = NULL;
	isc_mem_attach(mctx, &stats->mctx);
	stats->ncounters = ncounters;
	stats->magic = ISC_STATS_MAGIC;
	*statsp = stats;
}

isc_statscounter_t
isc_stats_increment(isc_stats_t *stats, isc_statscounter_t counter) {
	REQUIRE(ISC_STATS_VALID(stats));
	REQUIRE(counter < stats->ncounters);

	return atomic_fetch_add_relaxed(&stats->counters[counter], 1);
}

void
isc_stats_decrement(isc_stats_t *stats, isc_statscounter_t counter) {
	REQUIRE(ISC_STATS_VALID(stats));
	REQUIRE(counter < stats->ncounters);
#if ISC_STATS_CHECKUNDERFLOW
	REQUIRE(atomic_fetch_sub_release(&stats->counters[counter], 1) > 0);
#else
	atomic_fetch_sub_release(&stats->counters[counter], 1);
#endif
}

void
isc_stats_dump(isc_stats_t *stats, isc_stats_dumper_t dump_fn, void *arg,
	       unsigned int options) {
	int i;

	REQUIRE(ISC_STATS_VALID(stats));

	for (i = 0; i < stats->ncounters; i++) {
		isc_statscounter_t counter =
			atomic_load_acquire(&stats->counters[i]);
		if ((options & ISC_STATSDUMP_VERBOSE) == 0 && counter == 0) {
			continue;
		}
		dump_fn((isc_statscounter_t)i, counter, arg);
	}
}

void
isc_stats_set(isc_stats_t *stats, uint64_t val, isc_statscounter_t counter) {
	REQUIRE(ISC_STATS_VALID(stats));
	REQUIRE(counter < stats->ncounters);

	atomic_store_release(&stats->counters[counter], val);
}

void
isc_stats_update_if_greater(isc_stats_t *stats, isc_statscounter_t counter,
			    isc_statscounter_t value) {
	REQUIRE(ISC_STATS_VALID(stats));
	REQUIRE(counter < stats->ncounters);

	isc_statscounter_t curr_value =
		atomic_load_acquire(&stats->counters[counter]);
	do {
		if (curr_value >= value) {
			break;
		}
	} while (!atomic_compare_exchange_weak_acq_rel(
		&stats->counters[counter], &curr_value, value));
}

isc_statscounter_t
isc_stats_get_counter(isc_stats_t *stats, isc_statscounter_t counter) {
	REQUIRE(ISC_STATS_VALID(stats));
	REQUIRE(counter < stats->ncounters);

	return atomic_load_acquire(&stats->counters[counter]);
}

void
isc_stats_resize(isc_stats_t **statsp, int ncounters) {
	isc_stats_t *stats;
	size_t counters_alloc_size;
	isc_atomic_statscounter_t *newcounters;

	REQUIRE(statsp != NULL && *statsp != NULL);
	REQUIRE(ISC_STATS_VALID(*statsp));
	REQUIRE(ncounters > 0);

	stats = *statsp;
	if (stats->ncounters >= ncounters) {
		/* We already have enough counters. */
		return;
	}

	/* Grow number of counters. */
	counters_alloc_size = sizeof(isc_atomic_statscounter_t) * ncounters;
	newcounters = isc_mem_get(stats->mctx, counters_alloc_size);
	for (int i = 0; i < ncounters; i++) {
		atomic_init(&newcounters[i], 0);
	}
	for (int i = 0; i < stats->ncounters; i++) {
		uint32_t counter = atomic_load_acquire(&stats->counters[i]);
		atomic_store_release(&newcounters[i], counter);
	}
	isc_mem_cput(stats->mctx, stats->counters, stats->ncounters,
		     sizeof(isc_atomic_statscounter_t));
	stats->counters = newcounters;
	stats->ncounters = ncounters;
}
