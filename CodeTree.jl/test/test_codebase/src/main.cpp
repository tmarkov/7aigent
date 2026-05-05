#include "algorithms.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>

///
/// main.cpp — entry point and Sorter class.
/// Demonstrates use of algorithms.hpp from a client translation unit.
///

/* Section: Sorter class */

/// A stateful wrapper around the sorting routines.
///
/// Holds an internal integer array and provides a high-level interface for
/// sorting, searching, and reporting. Intended as a simple showcase of how
/// C++ classes interact with the free-function algorithms.
class Sorter {
public:
    /// Construct a Sorter from an existing array.
    /// The Sorter copies the data; the caller retains ownership of `data`.
    Sorter(const int *data, int n) : n_(n) {
        data_ = (int *)malloc(n * sizeof(int));
        memcpy(data_, data, n * sizeof(int));
    }

    ~Sorter() { free(data_); }

    /// Sort the internal array using the named algorithm.
    /// Valid names: "quick", "merge", "bucket".
    /// Returns false and prints a warning for unknown names.
    bool sort(const char *algorithm) {
        if (strcmp(algorithm, "quick") == 0) {
            quick_sort(data_, n_);
        } else if (strcmp(algorithm, "merge") == 0) {
            merge_sort(data_, n_);
        } else if (strcmp(algorithm, "bucket") == 0) {
            bucket_sort(data_, n_);
        } else {
            fprintf(stderr, "Sorter::sort: unknown algorithm '%s'\n", algorithm);
            return false;
        }
        sorted_ = true;
        return true;
    }

    /// Binary search for `target` in the sorted array.
    /// Returns the index, or -1 if not found or the array is not yet sorted.
    int find(int target) const {
        if (!sorted_) {
            fprintf(stderr, "Sorter::find: array not sorted\n");
            return -1;
        }
        int lo = 0, hi = n_ - 1;
        while (lo <= hi) {
            int mid = lo + (hi - lo) / 2;
            if (data_[mid] == target) return mid;
            else if (data_[mid] < target) lo = mid + 1;
            else hi = mid - 1;
        }
        return -1;
    }

    /// Print all elements to stdout, one per line.
    void print() const {
        for (int i = 0; i < n_; i++)
            printf("%d\n", data_[i]);
    }

    // Nested type: iterator over the sorted array.
    // R15: nested struct inside a class — forms its own landmark row.
    struct Iterator {
        const int *ptr;
        int        remaining;

        /// Advance the iterator and return the next value.
        /// Returns false when exhausted.
        bool next(int *out) {
            if (remaining <= 0) return false;
            *out = *ptr++;
            remaining--;
            return true;
        }
    };

    /// Return an iterator positioned at the beginning of the array.
    Iterator begin() const { return {data_, n_}; }

private:
    int  *data_;
    int   n_;
    bool  sorted_ = false;
};


/* Section: main */

// Entry point. Exercises Sorter and the free-function algorithms.
// R21: symbols table for this chunk should include calls to quick_sort,
//      merge_sort, process, timed_sort, and var_refs to MAX_N.
int main() {
    int data[] = {5, 3, 8, 1, 9, 2, 7, 4, 6, 0};
    int n = 10;

    // Demonstrate free-function calls (external symbols).
    quick_sort(data, n);
    process(data, n);

    SortResult result = timed_sort(data, n);
    printf("Sorted %d elements in %.3f ms\n", result.n, result.elapsed_ms);

    // Demonstrate class usage.
    int raw[] = {42, 17, 99, 3, 55};
    Sorter s(raw, 5);
    s.sort("merge");

    int idx = s.find(17);
    if (idx >= 0)
        printf("Found 17 at index %d\n", idx);

    s.print();

    // Boundary check using MAX_N (external variable reference).
    if (n < MAX_N)
        printf("n is within MAX_N limit\n");

    return 0;
}
