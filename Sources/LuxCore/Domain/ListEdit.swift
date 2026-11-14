import Foundation

/// One change to a list, whatever its rows: what the core's batches of diffs say, in Swift.
enum ListEdit<Row> {
    case append([Row]), clear, pushFront(Row), pushBack(Row), popFront, popBack
    case insert(Int, Row), set(Int, Row), remove(Int), truncate(Int), reset([Row])

    func map<Other>(_ transform: (Row) -> Other) -> ListEdit<Other> {
        switch self {
        case .append(let rows): .append(rows.map(transform))
        case .clear: .clear
        case .pushFront(let row): .pushFront(transform(row))
        case .pushBack(let row): .pushBack(transform(row))
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let row): .insert(index, transform(row))
        case .set(let index, let row): .set(index, transform(row))
        case .remove(let index): .remove(index)
        case .truncate(let length): .truncate(length)
        case .reset(let rows): .reset(rows.map(transform))
        }
    }
}

extension ListEdit: Sendable where Row: Sendable {}

extension Array {
    /// Applies the core's edits in order; an index past the end (which the core never sends) is
    /// ignored rather than trapping.
    mutating func apply(_ edits: [ListEdit<Element>]) {
        for edit in edits { apply(edit) }
    }

    mutating func apply(_ edit: ListEdit<Element>) {
        switch edit {
        case .append(let rows): append(contentsOf: rows)
        case .clear: removeAll()
        case .pushFront(let row): insert(row, at: 0)
        case .pushBack(let row): append(row)
        case .popFront: if !isEmpty { removeFirst() }
        case .popBack: if !isEmpty { removeLast() }
        case .insert(let index, let row): if index <= count { insert(row, at: index) }
        case .set(let index, let row): if indices.contains(index) { self[index] = row }
        case .remove(let index): if indices.contains(index) { remove(at: index) }
        case .truncate(let length): if length < count { removeSubrange(length...) }
        case .reset(let rows): self = rows
        }
    }
}
