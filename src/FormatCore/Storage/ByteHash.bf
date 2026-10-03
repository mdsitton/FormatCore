using System;
using System.Threading;
using internal FormatCore;

namespace FormatCore;

/// The seeded byte hash of the indexes and name tables (XmlNameTable's: whole words, overlapping at the
/// end and never read past it, the high half of a multiply at the end so every input bit reaches the
/// low bits a table masks). Seeds are per table, derived from a process seed (time and an address) and
/// a counter, so keys chosen to collide cannot be prepared in advance (hash flooding: TomlBeef's
/// TomlEntryMap hashed unseeded).
internal static class ByteHash
{
	static uint64 sProcessSeed = MakeProcessSeed();
	static int64 sCounter;

	static uint64 MakeProcessSeed()
	{
		int local = 0;
		uint64 seed = (uint64)DateTime.UtcNow.Ticks ^ ((uint64)(int)(void*)&local << 17);
		return SplitMix(seed ^ 0x9E3779B97F4A7C15UL);
	}

	/// @brief splitmix64's finalizer: every input bit reaches every output bit.
	/// @param x The value.
	/// @return The mixed value.
	[Inline]
	public static uint64 SplitMix(uint64 x)
	{
		var x;
		x ^= x >> 30;
		x &*= 0xBF58476D1CE4E5B9UL;
		x ^= x >> 27;
		x &*= 0x94D049BB133111EBUL;
		x ^= x >> 31;
		return x;
	}

	/// @brief A new seed for one table: distinct for every call in the process, unpredictable across
	/// processes. Never 0.
	/// @return The seed.
	public static uint64 NewSeed()
	{
		int64 n = Interlocked.Increment(ref sCounter);
		uint64 seed = SplitMix(sProcessSeed &+ (uint64)n &* 0x9E3779B97F4A7C15UL);
		return seed == 0 ? 1 : seed;
	}

	[Inline]
	static uint64 Mix(uint64 x)
	{
		uint64 m = x &* 0x9E3779B97F4A7C15UL;
		return m ^ (m >> 29);
	}

	/// @brief The hash of `ptr[0 ..< length]` under `seed`.
	/// @param ptr The bytes.
	/// @param length How many.
	/// @param seed The table's seed.
	/// @return The hash.
	[Inline]
	public static uint32 Hash(char8* ptr, int length, uint64 seed)
	{
		uint64 h = seed ^ ((uint64)length << 56);
		if (length >= 8)
		{
			int i = 0;
			while (i + 8 < length)
			{
				h = Mix(h ^ Swar.Load64(ptr + i));
				i += 8;
			}
			h = Mix(h ^ Swar.Load64(ptr + length - 8));
		}
		else if (length >= 4)
		{
			// The two words side by side (XmlNameTable shifted by 24, so their overlapping byte was ORed:
			// keys differing in the first and last bytes hashed equal under every seed)
			h = Mix(h ^ (((uint64)Swar.Load32(ptr) << 32) | Swar.Load32(ptr + length - 4)));
		}
		else if (length > 0)
			h = Mix(h ^ ((uint64)(uint8)ptr[0] | ((uint64)(uint8)ptr[length >> 1] << 8) | ((uint64)(uint8)ptr[length - 1] << 16)));
		// The high half of a multiply: every input bit reaches the slot bits
		h = (h ^ (h >> 32)) &* 0xD6E8FEB86659FD93UL;
		return (uint32)(h >> 32);
	}

	/// @brief The hash of `text` under `seed`.
	/// @param text The text.
	/// @param seed The table's seed.
	/// @return The hash.
	[Inline]
	public static uint32 Hash(StringView text, uint64 seed)
	{
		return Hash(text.Ptr, text.Length, seed);
	}
}

/// Resolves an index's IDs to their keys, so the index stores no keys.
internal interface IKeySource
{
	/// The key of `id` (never 0).
	StringView KeyOf(uint32 id);
}

/// An open-addressing index from keys to nonzero 32-bit IDs (JsonMemberIndex, XmlNameTable's slots,
/// TomlEntryMap's index): a power of two of slots, at most half full, probed linearly; a slot holds the
/// key's hash in its high half and the ID in its low half (0: empty), so a probe that misses reads no
/// key. Seeded per index: a default index takes a fresh seed (ByteHash.NewSeed) on its first hash.
/// Allocates nothing until the first insertion.
internal struct OpenIdIndex : IDisposable
{
	uint64* mSlots;
	int32 mMask;
	int32 mCount;
	uint64 mSeed;

	/// @brief An empty index with the given seed (tests force collisions with it; 0: a fresh one).
	/// @param seed The seed.
	public this(uint64 seed)
	{
		this = default;
		mSeed = seed;
	}

	/// @brief The number of keys.
	public int Count => mCount;

	/// @brief The number of slots (0 before the first insertion).
	public int SlotCount => mSlots == null ? 0 : mMask + 1;

	/// @brief The seed (0 until the first hash of a default index).
	public uint64 Seed => mSeed;

	/// @brief The hash of `key` in this index.
	/// @param key The key.
	/// @return The hash.
	[Inline]
	public uint32 HashOf(StringView key) mut
	{
		if (mSeed == 0)
			mSeed = ByteHash.NewSeed();
		return ByteHash.Hash(key.Ptr, key.Length, mSeed);
	}

	[Inline]
	static bool KeyEquals(StringView a, StringView b)
	{
		return a.Length == b.Length && Swar.EqualBytes(a.Ptr, b.Ptr, a.Length);
	}

	/// @brief The ID of `key`, or 0.
	/// @param keys The key source.
	/// @param key The key.
	/// @param hash `HashOf(key)`.
	/// @return The ID, or 0.
	[Inline]
	public uint32 Find<TKeys>(TKeys keys, StringView key, uint32 hash) where TKeys : IKeySource
	{
		if (mSlots == null)
			return 0;
		int32 pos = (int32)hash & mMask;
		while (true)
		{
			uint64 slot = mSlots[pos];
			if (slot == 0)
				return 0;
			if ((uint32)(slot >> 32) == hash && KeyEquals(keys.KeyOf((uint32)slot), key))
				return (uint32)slot;
			pos = (pos + 1) & mMask;
		}
	}

	/// @brief The ID of `key`, or 0 (hashing it first).
	/// @param keys The key source.
	/// @param key The key.
	/// @return The ID, or 0.
	[Inline]
	public uint32 Find<TKeys>(TKeys keys, StringView key) mut where TKeys : IKeySource
	{
		if (mSlots == null)
			return 0;
		return Find(keys, key, HashOf(key));
	}

	/// @brief The ID of `key`; when it is missing, `newId` is inserted for it (the caller then makes
	/// `keys.KeyOf(newId)` return it).
	/// @param keys The key source.
	/// @param key The key.
	/// @param hash `HashOf(key)`.
	/// @param newId The ID to insert (not 0).
	/// @param added Receives whether it was inserted.
	/// @return The ID.
	[Inline]
	public uint32 FindOrInsert<TKeys>(TKeys keys, StringView key, uint32 hash, uint32 newId, out bool added) mut where TKeys : IKeySource
	{
		if ((mCount + 1) * 2 > SlotCount)
			Grow();
		int32 pos = (int32)hash & mMask;
		while (true)
		{
			uint64 slot = mSlots[pos];
			if (slot == 0)
				break;
			if ((uint32)(slot >> 32) == hash && KeyEquals(keys.KeyOf((uint32)slot), key))
			{
				added = false;
				return (uint32)slot;
			}
			pos = (pos + 1) & mMask;
		}
		mSlots[pos] = ((uint64)hash << 32) | newId;
		mCount++;
		added = true;
		return newId;
	}

	/// @brief Map `key` to `id`, replacing the ID it had (the last duplicate wins).
	/// @param keys The key source (`keys.KeyOf(id)` is `key`).
	/// @param key The key.
	/// @param id The ID (not 0).
	public void Set<TKeys>(TKeys keys, StringView key, uint32 id) mut where TKeys : IKeySource
	{
		if ((mCount + 1) * 2 > SlotCount)
			Grow();
		uint32 hash = HashOf(key);
		int32 pos = (int32)hash & mMask;
		while (true)
		{
			uint64 slot = mSlots[pos];
			if (slot == 0)
			{
				mSlots[pos] = ((uint64)hash << 32) | id;
				mCount++;
				return;
			}
			if ((uint32)(slot >> 32) == hash && KeyEquals(keys.KeyOf((uint32)slot), key))
			{
				mSlots[pos] = ((uint64)hash << 32) | id;
				return;
			}
			pos = (pos + 1) & mMask;
		}
	}

	/// @brief Insert `id` with a known hash and no lookup: the caller knows its key is not in the index
	/// (a rebuild, a name table's own entries).
	/// @param hash The key's hash.
	/// @param id The ID (not 0).
	public void InsertNew(uint32 hash, uint32 id) mut
	{
		if ((mCount + 1) * 2 > SlotCount)
			Grow();
		Place(((uint64)hash << 32) | id);
		mCount++;
	}

	/// @brief Index `ids` from scratch (after removals or renames), sized for them, the last of equal
	/// keys winning.
	/// @param keys The key source.
	/// @param ids The IDs, in order.
	public void Rebuild<TKeys>(TKeys keys, Span<uint32> ids) mut where TKeys : IKeySource
	{
		int32 size = 16;
		while (size < ids.Length * 2 + 2)
			size *= 2;
		if (mSlots == null || mMask + 1 != size)
		{
			delete mSlots;
			Allocate(size);
		}
		else
			Internal.MemSet(mSlots, 0, size * sizeof(uint64));
		mCount = 0;
		for (let id in ids)
			Set(keys, keys.KeyOf(id), id);
	}

	/// @brief Remove every key, keeping the slots.
	public void Clear() mut
	{
		if (mSlots != null)
			Internal.MemSet(mSlots, 0, (mMask + 1) * sizeof(uint64));
		mCount = 0;
	}

	public void Dispose() mut
	{
		delete mSlots;
		mSlots = null;
		mMask = 0;
		mCount = 0;
	}

	/// @brief The bytes of the slots.
	public int ReservedBytes => SlotCount * sizeof(uint64);

	void Allocate(int32 size) mut
	{
		mSlots = new uint64[size]*;
		Internal.MemSet(mSlots, 0, size * sizeof(uint64));
		mMask = size - 1;
	}

	/// Doubles the slots (or makes the first 16), moving each by its stored hash: no key is read.
	[NoInline]
	void Grow() mut
	{
		uint64* old = mSlots;
		int32 oldSize = old == null ? 0 : mMask + 1;
		Allocate(Math.Max(oldSize * 2, 16));
		for (int32 i < oldSize)
		{
			if (old[i] != 0)
				Place(old[i]);
		}
		delete old;
	}

	[Inline]
	void Place(uint64 slot)
	{
		int32 pos = (int32)(uint32)(slot >> 32) & mMask;
		while (mSlots[pos] != 0)
			pos = (pos + 1) & mMask;
		mSlots[pos] = slot;
	}
}
