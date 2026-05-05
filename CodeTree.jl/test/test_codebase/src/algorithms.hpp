#pragma once

#include <cstdlib>  // for size_t, malloc, free

///
/// algorithms.hpp — declarations for sorting and processing routines.
/// Include this header in any translation unit that calls these functions.
///

/// Maximum array size accepted by bucket_sort.
extern const int MAX_N;

/// Result of a timed sort operation.
struct SortResult {
    int    *data;       ///< Pointer to sorted array (caller owns)
    int     n;          ///< Number of elements
    double  elapsed_ms; ///< Wall-clock time of the sort
};

/// Sort arr[0..n-1] in place using quicksort.
void quick_sort(int *arr, int n);

/// Sort arr[0..n-1] in place using merge sort (stable).
void merge_sort(int *arr, int n);

/// Sort arr[0..n-1] in place using counting/bucket sort.
/// Only valid for non-negative integer arrays with values < MAX_N.
void bucket_sort(int *arr, int n);

/// Sort arr[0..n-1] and return timing metadata.
SortResult timed_sort(int *arr, int n);

/// Process (sort) an integer array in place.
void process(int *arr, int n);

/// Process (sort) a double array in place.
/// R1: same base name as the int overload — will get id suffix `process$2`.
void process(double *arr, int n);

/// Swap two integers in place.
void swap(int *a, int *b);

/// Wacky-formatted function used to test R14a (shared-line boundary).
void wacky(int a, int b);
