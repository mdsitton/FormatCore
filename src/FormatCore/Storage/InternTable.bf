using System;
using internal FormatCore;

namespace FormatCore;

/// String interning (XmlBeef's XmlNameTable without its QName logic): each distinct string is stored
/// once, in text that never moves, and named by a nonzero `uint32` ID, so comparisons are integer
/// compares. The index is seeded per table; a 256-entry direct-mapped cache of recent strings (by
/// first byte, last byte and length) answers repeated names with one compare. Predefined strings get
/// IDs 1..n and survive Clear. ID 0 names nothing.
internal class InternTable
{
	struct Entry
	{
		public char8* mPtr;
		public int32 mLength;
		public uint32 mHash;
	}

	/// The index's key source.
	struct Keys : IKeySource
	{
		public Entry* mEntries;

		[Inline]
		public StringView KeyOf(uint32 id) => .(mEntries[id].mPtr, mEntries[id].mLength);
	}

	GrowList<Entry> mEntries ~ delete _;
	OpenIdIndex mIndex ~ _.Dispose();
	TextArena mText ~ delete _;
	/// The predefined strings' text (never reset).
	TextArena mFixedText ~ delete _;
	int mPredefined;
	uint32[256] mCache;

	/// @brief An empty table.
	/// @param predefined Strings that get IDs 1..n, through every Clear.
	public this(Span<StringView> predefined = default)
	{
		mEntries = new .();
		mText = new .();
		mFixedText = new .(256);
		mIndex = .(ByteHash.NewSeed());
		mEntries.Add(default);
		for (let text in predefined)
		{
			let copy = mFixedText.Copy(text);
			Add(copy, mIndex.HashOf(copy));
		}
		mPredefined = predefined.Length;
	}

	/// @brief The number of interned strings (predefined ones included).
	public int Count => mEntries.Count - 1;

	/// @brief The index's seed.
	public uint64 Seed => mIndex.Seed;

	[Inline]
	Keys MakeKeys() => .() { mEntries = mEntries.Ptr };

	/// @brief The ID of `text`, interning a copy of it if it is new.
	/// @param text The string.
	/// @return Its ID.
	[Inline]
	public uint32 Intern(StringView text)
	{
		uint32 hash = mIndex.HashOf(text);
		uint32 id = mIndex.FindOrInsert(MakeKeys(), text, hash, (uint32)mEntries.Count, let added);
		if (added)
		{
			Entry entry;
			entry.mPtr = mText.Alloc(Math.Max(text.Length, 1));
			Internal.MemCpy(entry.mPtr, text.Ptr, text.Length);
			entry.mLength = (int32)text.Length;
			entry.mHash = hash;
			mEntries.Add(entry);
		}
		return id;
	}

	void Add(StringView owned, uint32 hash)
	{
		Entry entry;
		entry.mPtr = owned.Ptr;
		entry.mLength = (int32)owned.Length;
		entry.mHash = hash;
		uint32 id = (uint32)mEntries.Count;
		mEntries.Add(entry);
		mIndex.InsertNew(hash, id);
	}

	/// @brief The ID of `text` if it is interned, else 0.
	/// @param text The string.
	/// @return Its ID, or 0.
	public uint32 Find(StringView text)
	{
		return mIndex.Find(MakeKeys(), text);
	}

	[Inline]
	static uint32 CacheIndex(StringView text)
	{
		int length = text.Length;
		return ((uint32)(uint8)text.Ptr[0] ^ ((uint32)(uint8)text.Ptr[length - 1] << 3) ^ ((uint32)length << 5)) & 0xFF;
	}

	[Inline]
	bool CacheHit(uint32 id, StringView text)
	{
		if (id == 0 || id >= (uint32)mEntries.Count)
			return false;
		ref Entry entry = ref mEntries[id];
		return entry.mLength == text.Length && Swar.EqualBytes(entry.mPtr, text.Ptr, text.Length);
	}

	/// @brief Intern with the recent-string cache in front (a reader's names).
	/// @param text The string (not empty).
	/// @return Its ID.
	[Inline]
	public uint32 InternCached(StringView text)
	{
		uint32 index = CacheIndex(text);
		// Not cleared with the table: an ID from before is checked against the entries like any other
		uint32 id = mCache[index];
		if (CacheHit(id, text))
			return id;
		id = Intern(text);
		mCache[index] = id;
		return id;
	}

	/// @brief Find with the recent-string cache in front.
	/// @param text The string.
	/// @return Its ID, or 0.
	[Inline]
	public uint32 FindCached(StringView text)
	{
		if (text.IsEmpty)
			return Find(text);
		uint32 index = CacheIndex(text);
		uint32 id = mCache[index];
		if (CacheHit(id, text))
			return id;
		id = Find(text);
		if (id != 0)
			mCache[index] = id;
		return id;
	}

	/// @brief The text of `id` (empty for 0). Valid until the table is cleared (predefined strings:
	/// while the table lives).
	public StringView this[uint32 id]
	{
		[Inline]
		get
		{
			ref Entry entry = ref mEntries[id];
			return .(entry.mPtr, entry.mLength);
		}
	}

	/// @brief Forget every string but the predefined ones (IDs from before become invalid), keeping
	/// the memory.
	public void Clear()
	{
		if (mEntries.Count == 1 + mPredefined)
			return;
		mEntries.Count = 1 + mPredefined;
		mText.Reset();
		ReindexPredefined();
	}

	/// @brief Clear, and free the memory the table grew to.
	public void Release()
	{
		mEntries.Count = 1 + mPredefined;
		mEntries.TrimExcess();
		mText.Release();
		mIndex.Dispose();
		ReindexPredefined();
	}

	void ReindexPredefined()
	{
		mIndex.Clear();
		for (int id = 1; id <= mPredefined; id++)
			mIndex.InsertNew(mEntries[id].mHash, (uint32)id);
	}

	/// @brief The bytes the table holds (entries, slots, text), approximately.
	public int ReservedBytes => mEntries.ReservedBytes + mIndex.ReservedBytes + mText.ReservedBytes + mFixedText.ReservedBytes;
}
