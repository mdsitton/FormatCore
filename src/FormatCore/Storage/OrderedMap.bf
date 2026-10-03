using System;
using internal FormatCore;

namespace FormatCore;

/// A slot type an OrderedMap holds: the format's entry with its key.
internal interface IKeyedSlot
{
	/// The entry's key (bytes owned by the document).
	StringView Key { get; set mut; }
}

/// Entries in insertion order with a hash index once they outgrow a short scan (TomlBeef's
/// TomlEntryMap, generalized over the slot type and the scan limit). Walking the entries never hashes;
/// up to `TLimit` entries a lookup compares keys directly (most tables: no hashing, no index); past
/// that an OpenIdIndex maps keys to positions + 1, **seeded per map**, so keys chosen to collide cannot
/// be prepared in advance. Removing or renaming rebuilds the index (both are rare, and removal shifts
/// positions anyway). Keys are unique: the format decides what a duplicate is (FindOrAdd finds it).
internal struct OrderedMap<TSlot, TLimit> : IDisposable where TSlot : struct, IKeyedSlot where TLimit : const int
{
	/// The index's key source: position + 1 to key.
	struct Keys : IKeySource
	{
		public TSlot* mSlots;

		[Inline]
		public StringView KeyOf(uint32 id) => mSlots[id - 1].Key;
	}

	TSlot* mSlots;
	int32 mCount;
	int32 mCapacity;
	/// Unused (no slots) while the map is small enough to scan.
	OpenIdIndex mIndex;
	bool mIndexed;

	/// @brief The number of entries.
	public int Count => mCount;

	/// @brief Whether the map has an index (more than TLimit entries).
	public bool IsIndexed => mIndexed;

	/// @brief The index's seed (0 before it is first built).
	public uint64 IndexSeed => mIndex.Seed;

	/// @brief Force the seed the index will use (tests; 0: a fresh one).
	/// @param seed The seed.
	public void SetIndexSeed(uint64 seed) mut
	{
		mIndex.Dispose();
		mIndex = .(seed);
		if (mIndexed)
			RebuildIndex();
	}

	/// @brief The entry at `index` (checked: callers pass public indices).
	public ref TSlot this[int index]
	{
		[Inline]
		get
		{
			Runtime.Assert((uint)index < (uint)mCount);
			return ref mSlots[index];
		}
	}

	public void Dispose() mut
	{
		delete mSlots;
		mIndex.Dispose();
		this = default;
	}

	/// @brief Remove every entry, keeping the allocated space.
	public void Clear() mut
	{
		mCount = 0;
		mIndex.Clear();
		mIndexed = false;
	}

	[Inline]
	static bool KeyEquals(StringView a, StringView b)
	{
		return a.Length == b.Length && Swar.EqualBytes(a.Ptr, b.Ptr, a.Length);
	}

	[Inline]
	Keys MakeKeys() => .() { mSlots = mSlots };

	/// @brief The position of the entry with `key`, or -1.
	/// @param key The key.
	/// @return The position, or -1.
	public int IndexOf(StringView key) mut
	{
		if (!mIndexed)
			return ScanFor(key);
		return (int)mIndex.Find(MakeKeys(), key) - 1;
	}

	/// @brief The position of the entry with `key`, appending a new entry (with that key view: the
	/// caller stores its own copy in the slot) when there is none, in one lookup.
	/// @param key The key.
	/// @param added Receives whether the entry is new.
	/// @return The position.
	public int FindOrAdd(StringView key, out bool added) mut
	{
		if (!mIndexed)
		{
			int found = ScanFor(key);
			if (found >= 0)
			{
				added = false;
				return found;
			}
			added = true;
			int index = Append(key);
			if (mCount > TLimit)
				RebuildIndex();
			return index;
		}
		uint32 hash = mIndex.HashOf(key);
		// The new entry would be at mCount: its ID is mCount + 1 (its slot exists once appended)
		uint32 id = mIndex.FindOrInsert(MakeKeys(), key, hash, (uint32)mCount + 1, out added);
		if (!added)
			return (int)id - 1;
		return Append(key);
	}

	/// @brief Remove the entry at `index`, keeping the order of the rest.
	/// @param index The position.
	public void RemoveAt(int index) mut
	{
		Runtime.Assert((uint)index < (uint)mCount);
		int after = mCount - index - 1;
		if (after > 0)
			Internal.MemMove(&mSlots[index], &mSlots[index + 1], after * strideof(TSlot), alignof(TSlot));
		mCount--;
		if (mIndexed)
			RebuildIndex();
	}

	/// @brief Change the key of the entry at `index` (the caller checked that `key` is not in use).
	/// @param index The position.
	/// @param key The new key, owned by the document.
	public void SetKeyAt(int index, StringView key) mut
	{
		this[index].Key = key;
		if (mIndexed)
			RebuildIndex();
	}

	int ScanFor(StringView key)
	{
		for (int i < mCount)
		{
			if (KeyEquals(mSlots[i].Key, key))
				return i;
		}
		return -1;
	}

	int Append(StringView key) mut
	{
		if (mCount == mCapacity)
		{
			int32 capacity = Math.Max(mCapacity * 2, 4);
			TSlot* slots = new TSlot[capacity]*;
			if (mCount > 0)
				Internal.MemCpy(slots, mSlots, mCount * strideof(TSlot), alignof(TSlot));
			delete mSlots;
			mSlots = slots;
			mCapacity = capacity;
		}
		mSlots[mCount] = default;
		mSlots[mCount].Key = key;
		return mCount++;
	}

	void RebuildIndex() mut
	{
		if (mCount <= TLimit)
		{
			// Small again (after removals): back to scanning
			mIndex.Clear();
			mIndexed = false;
			return;
		}
		mIndexed = true;
		// Keys are distinct: each entry is placed by its hash, no key compared
		mIndex.RebuildDistinct(MakeKeys(), mCount);
	}

	/// @brief The bytes the map holds.
	public int ReservedBytes => mCapacity * strideof(TSlot) + mIndex.ReservedBytes;
}
