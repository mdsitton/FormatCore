using System;
using internal FormatCore;

namespace FormatCore;

/// A growable array of values (XmlBeef's XmlStack and JsonBeef's JsonStack, merged) for node tables
/// and builder stacks: `Add`, `PopBack`, `Back` and the indexer are inlined, which corlib's List.Add and
/// Count setter are not (each showed up in XmlBeef's profiles). The items are a raw allocation, as in
/// corlib's List (an array object's header cost KdlBeef's writer 0.2% in item reads). Items are not
/// bounds-checked.
internal class GrowList<T> where T : struct
{
	T* mItems;
	int mCapacity;
	int mCount;

	/// @brief An empty list.
	/// @param capacity The first capacity (at least 1).
	public this(int capacity = 16)
	{
		mCapacity = Math.Max(capacity, 1);
		mItems = new T[mCapacity]*;
	}

	public ~this()
	{
		delete mItems;
	}

	/// @brief The number of items; setting it lower (never higher) drops the items above.
	public int Count
	{
		[Inline]
		get => mCount;
		[Inline]
		set => mCount = value;
	}

	/// @brief Whether there are no items.
	public bool IsEmpty
	{
		[Inline]
		get => mCount == 0;
	}

	/// @brief The number of items the array holds before it grows.
	public int Capacity
	{
		[Inline]
		get => mCapacity;
	}

	/// @brief Append an item.
	/// @param item The item.
	[Inline]
	public void Add(T item)
	{
		if (mCount == mCapacity)
			Grow();
		mItems[mCount++] = item;
	}

	/// @brief Append a default item.
	/// @return The new item.
	[Inline]
	public ref T AddDefault()
	{
		if (mCount == mCapacity)
			Grow();
		mItems[mCount] = default;
		return ref mItems[mCount++];
	}

	/// @brief Append `count` items left as they are (set them through the pointer).
	/// @param count How many.
	/// @return The first new item (one past the end when `count` is 0, even at full capacity).
	public T* GrowUninitialized(int count)
	{
		if (mCount + count > mCapacity)
			Reserve(mCount + count);
		T* first = mItems + mCount;
		mCount += count;
		return first;
	}

	/// @brief Make room for at least `capacity` items (doubling at least).
	/// @param capacity The capacity.
	public void Reserve(int capacity)
	{
		if (capacity <= mCapacity)
			return;
		Reallocate(Math.Max(capacity, mCapacity * 2));
	}

	void Reallocate(int capacity)
	{
		T* old = mItems;
		mItems = new T[capacity]*;
		mCapacity = capacity;
		Internal.MemCpy(mItems, old, mCount * strideof(T), alignof(T));
		delete old;
	}

	/// @brief Free the capacity beyond the items, keeping at least `minimum`.
	/// @param minimum The smallest capacity to keep.
	public void TrimExcess(int minimum = 16)
	{
		int capacity = Math.Max(Math.Max(mCount, minimum), 1);
		if (capacity >= mCapacity)
			return;
		Reallocate(capacity);
	}

	/// @brief The bytes of the array.
	public int ReservedBytes => mCapacity * strideof(T);

	[NoInline]
	void Grow()
	{
		Reserve(mCapacity * 2);
	}

	/// @brief Remove and return the last item.
	/// @return The item.
	[Inline]
	public T PopBack()
	{
		return mItems[--mCount];
	}

	/// @brief The last item.
	public ref T Back
	{
		[Inline]
		get => ref mItems[mCount - 1];
	}

	/// @brief The item at `index`.
	public ref T this[int index]
	{
		[Inline]
		get => ref mItems[index];
	}

	/// @brief The first item's address (valid until the list grows).
	public T* Ptr
	{
		[Inline]
		get => mItems;
	}

	/// @brief Remove every item (the capacity stays).
	[Inline]
	public void Clear()
	{
		mCount = 0;
	}

	/// @brief The items as a span (valid until the list changes).
	public Span<T> Span => .(mItems, mCount);
}

/// A stack of bits, one per nesting level (JsonBeef's object/array bits): push, pop and read the top
/// without allocating up to 64 levels, and in a growing array beyond. A reader that keeps its depth in
/// a field of its own (to restore it, as JsonBeef's push reader does) uses `Set` and `Get` by level and
/// leaves `Depth` alone.
internal struct BitStack : IDisposable
{
	uint64 mLow;
	uint64[] mHigh;
	int mDepth;

	/// @brief The number of bits.
	public int Depth
	{
		[Inline]
		get => mDepth;
	}

	/// @brief Push a bit.
	/// @param bit The bit.
	[Inline]
	public void Push(bool bit) mut
	{
		Set(mDepth, bit);
		mDepth++;
	}

	/// @brief Set the bit of `level` (0-based), growing the storage; the depth is unchanged.
	/// @param level The level.
	/// @param bit The bit.
	[Inline]
	public void Set(int level, bool bit) mut
	{
		if (level < 64)
		{
			if (bit)
				mLow |= 1UL << level;
			else
				mLow &= ~(1UL << level);
			return;
		}
		SetHigh(level, bit);
	}

	void SetHigh(int level, bool bit) mut
	{
		int index = (level - 64) >> 6;
		if (mHigh == null || index >= mHigh.Count)
		{
			uint64[] old = mHigh;
			mHigh = new uint64[Math.Max(index + 1, old == null ? 4 : old.Count * 2)];
			if (old != null)
			{
				Internal.MemCpy(mHigh.Ptr, old.Ptr, old.Count * 8);
				delete old;
			}
		}
		uint64 mask = 1UL << ((level - 64) & 63);
		if (bit)
			mHigh[index] |= mask;
		else
			mHigh[index] &= ~mask;
	}

	/// @brief The bit of `level` (0-based), which must have been set or pushed.
	/// @param level The level.
	/// @return The bit.
	[Inline]
	public bool Get(int level)
	{
		if (level < 64)
			return ((mLow >> level) & 1) != 0;
		return ((mHigh[(level - 64) >> 6] >> ((level - 64) & 63)) & 1) != 0;
	}

	/// @brief The top bit (the stack must not be empty).
	public bool Top
	{
		[Inline]
		get => Get(mDepth - 1);
	}

	/// @brief Remove the top bit.
	/// @return The bit.
	[Inline]
	public bool Pop() mut
	{
		bool bit = Top;
		mDepth--;
		return bit;
	}

	/// @brief Remove every bit (the storage stays).
	public void Clear() mut
	{
		mDepth = 0;
	}

	public void Dispose() mut
	{
		delete mHigh;
		mHigh = null;
		mDepth = 0;
	}
}

/// The bytes a string with escapes decodes to (JsonBeef's JsonDecodeBuffer). Decoding loops write
/// through a local pointer `dest`, checking `dest + needed > limit` before each write and calling
/// `Grow` (out of line) only then, instead of a String.Append per escape and per plain run.
internal class DecodeBuffer
{
	char8* mPtr;
	int mCapacity;

	/// @brief A buffer of `capacity` bytes.
	/// @param capacity The first capacity.
	public this(int capacity = 256)
	{
		mCapacity = Math.Max(capacity, 16);
		mPtr = new char8[mCapacity]*;
	}

	public ~this()
	{
		delete mPtr;
	}

	/// @brief The first byte (valid until the buffer grows).
	public char8* Ptr
	{
		[Inline]
		get => mPtr;
	}

	/// @brief One past the last byte.
	public char8* Limit
	{
		[Inline]
		get => mPtr + mCapacity;
	}

	/// @brief The capacity in bytes.
	public int Capacity => mCapacity;

	/// @brief Grow the buffer so that `needed` more bytes fit at `dest` (the bytes before it kept),
	/// moving `dest` and `limit` with it.
	/// @param dest The write position (updated).
	/// @param limit The limit (updated).
	/// @param needed The bytes about to be written.
	[NoInline]
	public void Grow(ref char8* dest, ref char8* limit, int needed)
	{
		int length = dest - mPtr;
		int capacity = Math.Max(mCapacity * 2, length + needed);
		char8* grown = new char8[capacity]*;
		Internal.MemCpy(grown, mPtr, length);
		delete mPtr;
		mPtr = grown;
		mCapacity = capacity;
		dest = mPtr + length;
		limit = mPtr + mCapacity;
	}

	/// @brief Copy `count` bytes from `source` to `dest` (room for `count + 16` made first). A run of up
	/// to 16 bytes is copied as two 8-byte words when `source` may be read 16 bytes far (`readable`):
	/// escapes come in clusters, so most runs between them are short and a memcpy call would cost more.
	/// @param dest Where to copy to.
	/// @param source Where to copy from.
	/// @param count How many bytes.
	/// @param readable Whether `source[0 ..< 16]` may be read.
	[Inline]
	public static void CopyRun(char8* dest, char8* source, int count, bool readable)
	{
		if (count <= 16 && readable)
		{
			*(uint64*)dest = *(uint64*)source;
			*(uint64*)(dest + 8) = *(uint64*)(source + 8);
		}
		else
			Internal.MemCpy(dest, source, count);
	}
}
