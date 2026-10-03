using System;
using internal FormatCore;

namespace FormatCore;

/// Per-item records kept beside an item table (source ranges, PreserveStyle records), indexed like it
/// (KdlBeef's and XmlBeef's SideCopy/SideClear/SideRemove). A table is in use when it is not empty;
/// items added since it was filled have default records, so every operation first grows it to the
/// item table's count. An unused table costs one empty check per operation.
internal class SideTable<T> where T : struct
{
	GrowList<T> mItems ~ delete _;

	public this()
	{
		mItems = new .(1);
	}

	/// @brief Whether the table holds records (it was filled, e.g. by a read with positions).
	public bool InUse
	{
		[Inline]
		get => mItems.Count > 0;
	}

	/// @brief Whether the table holds no records (not in use).
	public bool IsEmpty
	{
		[Inline]
		get => mItems.Count == 0;
	}

	/// @brief The number of records.
	public int Count => mItems.Count;

	/// @brief The record at `index`, which must be below Count (no growth: At grows).
	public ref T this[int index]
	{
		[Inline]
		get => ref mItems[index];
	}

	/// @brief The record at `index`, growing the table with default records to reach it (which puts
	/// the table in use).
	/// @param index The item index.
	/// @return The record.
	public ref T At(int index)
	{
		if (index >= mItems.Count)
			GrowTo(index + 1);
		return ref mItems[index];
	}

	/// @brief The record at `index` if the table has one, else the default.
	/// @param index The item index.
	/// @return The record.
	[Inline]
	public T Get(int index)
	{
		return index < mItems.Count ? mItems[index] : default;
	}

	/// @brief Append a record (a reader filling the table in item order).
	/// @param record The record.
	[Inline]
	public void Add(T record)
	{
		mItems.Add(record);
	}

	void GrowTo(int count)
	{
		int from = mItems.Count;
		if (count <= from)
			return;
		T* added = mItems.GrowUninitialized(count - from);
		Internal.MemSet(added, 0, (count - from) * strideof(T));
	}

	/// @brief Copy the records of items `[from, from + count)` to `[to, to + count)` (an item range
	/// moved within the item table, which has `itemCount` items). Does nothing when not in use.
	/// @param from The first source index.
	/// @param to The first destination index.
	/// @param count How many.
	/// @param itemCount The item table's count.
	public void Copy(int from, int to, int count, int itemCount)
	{
		if (!InUse)
			return;
		GrowTo(itemCount);
		Internal.MemMove(mItems.Ptr + to, mItems.Ptr + from, count * strideof(T), alignof(T));
	}

	/// @brief Reset the record at `at` (a new item there).
	/// @param at The index.
	/// @param itemCount The item table's count.
	public void ClearAt(int at, int itemCount)
	{
		if (!InUse)
			return;
		GrowTo(itemCount);
		mItems[at] = default;
	}

	/// @brief Remove the record at `at` from the range ending at `end`: the records after it move down
	/// one (the item table did the same).
	/// @param at The removed index.
	/// @param end The end of the item range.
	/// @param itemCount The item table's count.
	public void RemoveAt(int at, int end, int itemCount)
	{
		if (!InUse)
			return;
		GrowTo(itemCount);
		if (end - at > 1)
			Internal.MemMove(mItems.Ptr + at, mItems.Ptr + at + 1, (end - at - 1) * strideof(T), alignof(T));
	}

	/// @brief Renumber for a compaction: the record of old index `i` moves to `newIndexOf[i]` (or is
	/// dropped when that is -1); the table then has `newCount` records.
	/// @param newIndexOf The new index of each old index (old indices past it are dropped).
	/// @param newCount The new item count.
	public void Remap(Span<int32> newIndexOf, int newCount)
	{
		if (!InUse)
			return;
		GrowTo(newIndexOf.Length);
		let old = new T[mItems.Count];
		defer delete old;
		Internal.MemCpy(old.Ptr, mItems.Ptr, mItems.Count * strideof(T), alignof(T));
		mItems.Clear();
		GrowTo(newCount);
		for (int i < newIndexOf.Length)
		{
			int32 to = newIndexOf[i];
			if (to >= 0)
				mItems[to] = old[i];
		}
	}

	/// @brief Empty the table (not in use any more), keeping its memory.
	public void Clear()
	{
		mItems.Clear();
	}

	/// @brief Empty the table and free its memory.
	public void Release()
	{
		mItems.Clear();
		mItems.TrimExcess(1);
	}

	/// @brief The bytes the table holds.
	public int ReservedBytes => mItems.ReservedBytes;
}

/// A node's items in a document-wide item table: KDL's entries, XML's attributes.
internal struct ItemRange
{
	public int32 mStart;
	public int32 mCount;
	/// Slots reserved at mStart (≥ mCount); the slots past mCount are free.
	public int32 mCapacity;

	/// @brief One past the last item.
	public int32 End => mStart + mCount;
}

/// What follows items when RangeTable moves them: the format's side tables.
internal interface IItemMoves
{
	/// Items `[from, from + count)` were copied to `[to, to + count)`.
	void Copy(int from, int to, int count, int itemCount) mut;
	/// A new item was put at `at`.
	void ClearAt(int at, int itemCount) mut;
	/// The item at `at` was removed from the range ending at `end`.
	void RemoveAt(int at, int end, int itemCount) mut;
}

/// No side tables.
internal struct NoItemMoves : IItemMoves
{
	[Inline]
	public void Copy(int from, int to, int count, int itemCount) mut
	{
	}

	[Inline]
	public void ClearAt(int at, int itemCount) mut
	{
	}

	[Inline]
	public void RemoveAt(int at, int end, int itemCount) mut
	{
	}
}

/// Up to two side tables following the items (KDL and XML each keep ranges and styles).
internal struct SideMoves<T1, T2> : IItemMoves where T1 : struct where T2 : struct
{
	public SideTable<T1> mFirst;
	public SideTable<T2> mSecond;

	public this(SideTable<T1> first, SideTable<T2> second)
	{
		mFirst = first;
		mSecond = second;
	}

	public void Copy(int from, int to, int count, int itemCount) mut
	{
		mFirst?.Copy(from, to, count, itemCount);
		mSecond?.Copy(from, to, count, itemCount);
	}

	public void ClearAt(int at, int itemCount) mut
	{
		mFirst?.ClearAt(at, itemCount);
		mSecond?.ClearAt(at, itemCount);
	}

	public void RemoveAt(int at, int end, int itemCount) mut
	{
		mFirst?.RemoveAt(at, end, itemCount);
		mSecond?.RemoveAt(at, end, itemCount);
	}
}

/// Every node's items in one table, each node owning a range (KdlBeef's AppendEntry/RemoveEntry,
/// XmlBeef's AppendAttribute/RemoveAttributeAt). Appending grows a range in place when it has a free
/// slot or ends the table; otherwise the range moves to the end, with room to grow, leaving a hole
/// until the document is compacted or cleared. Removing shifts the rest of the range down.
internal class RangeTable<TItem> where TItem : struct
{
	GrowList<TItem> mItems ~ delete _;

	public this(int capacity = 16)
	{
		mItems = new .(capacity);
	}

	/// @brief The number of item slots (holes included).
	public int Count
	{
		[Inline]
		get => mItems.Count;
	}

	/// @brief The item at table index `index`.
	public ref TItem this[int index]
	{
		[Inline]
		get => ref mItems[index];
	}

	/// @brief Append a range's items while building (the range must be the table's last).
	/// @param range The range (its start set on its first item).
	/// @param item The item.
	[Inline]
	public void AddBuilding(ref ItemRange range, TItem item)
	{
		if (range.mCount == 0)
			range.mStart = (int32)mItems.Count;
		mItems.Add(item);
		range.mCount++;
		range.mCapacity = range.mCount;
	}

	/// @brief Append `item` to `range`, in place when it can, else moving the range to the end.
	/// @param range The range (updated).
	/// @param item The item.
	/// @param moves The side tables to keep in step.
	/// @return The item's table index.
	public int Append<TMoves>(ref ItemRange range, TItem item, ref TMoves moves) where TMoves : IItemMoves
	{
		int32 end = range.End;
		if (range.mCount == range.mCapacity)
		{
			if (end == mItems.Count)
			{
				// The range ends the table: extend it
				mItems.AddDefault();
				range.mCapacity++;
			}
			else
			{
				int32 capacity = Math.Max(range.mCount * 2, 4);
				int32 newStart = (int32)mItems.Count;
				TItem* slots = mItems.GrowUninitialized(capacity);
				Internal.MemSet(slots, 0, capacity * strideof(TItem));
				for (int32 i < range.mCount)
					mItems[newStart + i] = mItems[range.mStart + i];
				moves.Copy(range.mStart, newStart, range.mCount, mItems.Count);
				range.mStart = newStart;
				range.mCapacity = capacity;
			}
			end = range.End;
		}
		mItems[end] = item;
		moves.ClearAt(end, mItems.Count);
		range.mCount++;
		return end;
	}

	/// @brief Remove the item at `index` within `range` (0-based), keeping the order of the rest.
	/// @param range The range (updated).
	/// @param index The item's index within the range.
	/// @param moves The side tables to keep in step.
	public void RemoveAt<TMoves>(ref ItemRange range, int index, ref TMoves moves) where TMoves : IItemMoves
	{
		int at = range.mStart + index;
		int end = range.End;
		for (int i = at; i < end - 1; i++)
			mItems[i] = mItems[i + 1];
		moves.RemoveAt(at, end, mItems.Count);
		range.mCount--;
	}

	/// @brief The items of `range` (valid until the table changes).
	/// @param range The range.
	/// @return The items.
	[Inline]
	public Span<TItem> Span(ItemRange range)
	{
		return .(mItems.Ptr + range.mStart, range.mCount);
	}

	/// @brief Remove every item (ranges become invalid), keeping the memory.
	public void Clear()
	{
		mItems.Clear();
	}

	/// @brief The bytes the table holds.
	public int ReservedBytes => mItems.ReservedBytes;
}
