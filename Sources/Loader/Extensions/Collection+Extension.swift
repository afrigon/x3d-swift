extension Collection {
    /// Bounds-checked subscript. Returns `nil` instead of trapping when `index` is out of range.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
