#include "algorithms.hpp"
#include <cstdio>
#include <cstdlib>
#include <ctime>

///////////////////////
/// SORTING LIBRARY ///
///////////////////////
//
// This file implements the sorting routines declared in algorithms.hpp.
// File-level comment block: part of the file node's first chunk (R15).


/* Section: globals and helpers */

// R15: MAX_N and swap are between the file header and the first function.
// They form a chunk between the section comment and quick_sort.

const int MAX_N = 1000000;

// This comment is separated from swap() by a blank line below.
// R14b (negative case): the blank line prevents absorption into swap's span.
// The comment is a standalone node at the file level, not part of swap.

void swap(int *a, int *b) {
    // R20: swap has no immediately-preceding comment (blank line above breaks
    // R14b absorption), so its summary is `missing`.
    int tmp = *a;
    *a = *b;
    *b = tmp;
}


/* Section: comparison sorts */
// R20a: the two /* Section: ... */ comments above are standalone kind=comment
// nodes (blank lines on both sides). Their summaries come from their own text.


// Quick sort: average O(n log n), worst case O(n^2).
// Very fast in practice due to cache efficiency and small constant.
void quick_sort(int *arr, int n) {
    // R14b: the two comment lines above are absorbed into quick_sort's span.
    // R11: quick_sort is ~23 lines total (< detail_threshold=30), so inner
    // conditionals and loops do NOT produce detail rows in db.code.
    if (n <= 1) return;

    int pivot = arr[n / 2];
    int left = 0, right = n - 1;

    // Partition around pivot.
    while (left <= right) {
        while (arr[left] < pivot)  left++;
        while (arr[right] > pivot) right--;
        if (left <= right) {
            swap(&arr[left], &arr[right]);
            left++;
            right--;
        }
    }

    // Recurse on both halves.
    quick_sort(arr, right + 1);
    quick_sort(arr + left, n - left);
}


// Merge sort: O(n log n) worst case, stable sort.
// Allocates a temporary buffer of size n; prefer over quick_sort when
// stability matters or worst-case guarantees are required.
void merge_sort(int *arr, int n) {
    // R14b: three comment lines absorbed into merge_sort's span.
    // R11: merge_sort spans ~35 lines (> detail_threshold=30), so inner
    // loops and conditionals DO produce detail rows in db.code.
    if (n <= 1) return;

    int mid = n / 2;
    merge_sort(arr, mid);
    merge_sort(arr + mid, n - mid);

    // Allocate temporary buffer for the merge step.
    int *tmp = (int *)malloc(n * sizeof(int));
    if (!tmp) {
        fprintf(stderr, "merge_sort: allocation failed\n");
        return;
    }

    // Merge the two sorted halves into tmp.
    int i = 0, j = mid, k = 0;
    while (i < mid && j < n) {
        if (arr[i] <= arr[j])
            tmp[k++] = arr[i++];
        else
            tmp[k++] = arr[j++];
    }
    while (i < mid) tmp[k++] = arr[i++];
    while (j < n)   tmp[k++] = arr[j++];

    // Copy merged result back into arr and release buffer.
    for (int idx = 0; idx < n; idx++)
        arr[idx] = tmp[idx];
    free(tmp);
}


/* Section: non-comparison sorts */


// Bucket/counting sort: O(n + range). Only valid for non-negative integers.
// Falls back with an error message if n >= MAX_N.
void bucket_sort(int *arr, int n) {
    if (n >= MAX_N) {
        fprintf(stderr, "bucket_sort: n=%d exceeds MAX_N\n", n);
        return;
    }
    int min_val = arr[0], max_val = arr[0];
    for (int i = 1; i < n; i++) {
        if (arr[i] < min_val) min_val = arr[i];
        if (arr[i] > max_val) max_val = arr[i];
    }
    int range = max_val - min_val + 1;
    int *counts = (int *)calloc(range, sizeof(int));
    for (int i = 0; i < n; i++)
        counts[arr[i] - min_val]++;
    for (int pos = 0, i = 0; i < range; i++)
        while (counts[i]-- > 0)
            arr[pos++] = i + min_val;
    free(counts);
}


/* Section: timed sort */


// Run quick_sort and record elapsed wall-clock time in milliseconds.
SortResult timed_sort(int *arr, int n) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    quick_sort(arr, n);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double elapsed = (t1.tv_sec - t0.tv_sec) * 1000.0
                   + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    SortResult r;
    r.data       = arr;
    r.n          = n;
    r.elapsed_ms = elapsed;
    return r;
}


/* Section: overloaded process (R1 duplicate names) */

// Sort an integer array in place by delegating to quick_sort.
void process(int *arr, int n) {
    quick_sort(arr, n);
}

// Sort a double array in place (truncates to int — toy example).
// R1: same base name as the int overload. This node gets id suffix `process$2`
// and qname suffix `process$2` because it is the second sibling named process.
void process(double *arr, int n) {
    for (int i = 0; i < n; i++)
        arr[i] = (double)((int)arr[i]);
    quick_sort((int *)arr, n);
}


/* Section: edge-case formatting */

// Wacky function: tests R14a (shared-line boundary).
// The line `} /* not-else */ if (a >= b) {` is shared between the closing
// brace of the first if-body and the start of the second if-statement.
// Per R14a that line belongs to the SECOND compound node.
void wacky(int a, int b) {
    if (a < b) {
        printf("less\n");
    } /* not-else */ if (a >= b) {
        printf("not less\n");
    }
}
