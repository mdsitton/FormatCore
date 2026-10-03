using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore;

/// Plain bytes in chunks that never move, for text with one lifetime (a document's, a name table's;
/// XmlBeef's XmlTextArena, JsonBeef's JsonTextArena). `Reset` keeps every chunk for reuse, so reading
/// document after document allocates nothing once the arena has grown to the largest (corlib's
/// BumpAllocator has no reset: recreating one per small document was measurable on many small files).
/// Bytes are unaligned: text only.
internal class TextArena
{
	List<uint8[]> mChunks ~ DeleteContainerAndItems!(_);
	/// The chunk being filled (-1: none yet since the last reset), where it is filled to, and its end.
	int mCurrent = -1;
	uint8* mNext;
	uint8* mLimit;
	int mFirstSize;

	/// @brief An empty arena.
	/// @param firstChunkBytes The first chunk's size (later chunks double, up to 1 MiB).
	public this(int firstChunkBytes = 4096)
	{
		mChunks = new .();
		mFirstSize = Math.Max(firstChunkBytes, 1);
	}

	/// @brief `size` bytes (unaligned), valid until the arena is reset or deleted.
	/// @param size The number of bytes.
	/// @return The first byte.
	[Inline]
	public char8* Alloc(int size)
	{
		if (mNext == null || (int)(void*)mLimit - (int)(void*)mNext < size)
			NextChunk(size);
		char8* p = (char8*)mNext;
		mNext += size;
		return p;
	}

	/// Moves to the next kept chunk that holds `size` bytes, or adds one (doubling, from mFirstSize up
	/// to 1 MiB, or `size` if that is more).
	[NoInline]
	void NextChunk(int size)
	{
		while (++mCurrent < mChunks.Count)
		{
			let chunk = mChunks[mCurrent];
			if (chunk.Count >= size)
			{
				mNext = chunk.Ptr;
				mLimit = chunk.Ptr + chunk.Count;
				return;
			}
		}
		int chunkSize = mChunks.IsEmpty ? mFirstSize : Math.Clamp(mChunks.Back.Count * 2, 4096, 1 << 20);
		let chunk = new uint8[Math.Max(Math.Max(chunkSize, size), 1)];
		mChunks.Add(chunk);
		mCurrent = mChunks.Count - 1;
		mNext = chunk.Ptr;
		mLimit = chunk.Ptr + chunk.Count;
	}

	/// @brief Forget everything allocated, keeping the chunks for the next use.
	public void Reset()
	{
		mCurrent = -1;
		mNext = null;
		mLimit = null;
	}

	/// @brief Forget everything allocated and free the chunks.
	public void Release()
	{
		Reset();
		ClearAndDeleteItems!(mChunks);
		mChunks.Capacity = 0;
	}

	/// @brief The bytes of every chunk.
	public int ReservedBytes
	{
		get
		{
			int total = 0;
			for (let chunk in mChunks)
				total += chunk.Count;
			return total;
		}
	}

	/// @brief The bytes of the chunks in use since the last reset: those passed over in full (their
	/// unused ends included), and the current one up to where it is filled.
	public int FilledBytes
	{
		get
		{
			if (mCurrent < 0 || mCurrent >= mChunks.Count)
				return 0;
			int total = 0;
			for (int i < mCurrent)
				total += mChunks[i].Count;
			return total + (int)(void*)mNext - (int)(void*)mChunks[mCurrent].Ptr;
		}
	}

	/// @brief A copy of `text` in the arena. An empty copy still has a non-null pointer (callers may use
	/// a null pointer for "absent", as TomlBeef's comment sets do).
	/// @param text The text.
	/// @return The copy.
	public StringView Copy(StringView text)
	{
		if (text.IsEmpty)
			return "";
		char8* bytes = Alloc(text.Length);
		Internal.MemCpy(bytes, text.Ptr, text.Length);
		return .(bytes, text.Length);
	}
}

/// A document's copy of its input and the rule "a view into it is kept, anything else is copied"
/// (XmlBeef's Own, JsonBeef's TextRef): strings read without decoding stay views of the source.
internal struct KeptSource
{
	char8* mPtr;
	int mLength;

	/// @brief The kept text.
	public StringView Text => .(mPtr, mLength);

	/// @brief Whether a source is kept.
	public bool IsSet => mPtr != null;

	/// @brief Keep `owned` (owned by the document, e.g. in its arena).
	/// @param owned The source copy.
	public void Set(StringView owned) mut
	{
		mPtr = owned.Ptr;
		mLength = owned.Length;
	}

	/// @brief Forget the source.
	public void Clear() mut
	{
		mPtr = null;
		mLength = 0;
	}

	/// @brief Whether `text` lies within the kept source.
	/// @param text The text.
	/// @return Whether it does.
	[Inline]
	public bool Contains(StringView text)
	{
		return mPtr != null && text.Ptr >= mPtr && text.Ptr + text.Length <= mPtr + mLength;
	}

	/// @brief `text` itself when it lies within the kept source, else a copy in `arena`.
	/// @param text The text.
	/// @param arena Where to copy anything else.
	/// @return A view that lives as long as the document.
	[Inline]
	public StringView Own(StringView text, TextArena arena)
	{
		if (Contains(text))
			return text;
		return arena.Copy(text);
	}

	/// @brief The offset of `text` in the kept source (it must lie within it).
	/// @param text The text.
	/// @return The offset.
	[Inline]
	public int OffsetOf(StringView text)
	{
		return text.Ptr - mPtr;
	}
}
