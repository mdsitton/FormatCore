using System;
using internal FormatCore;

namespace FormatCore;

/// Word-at-a-time (SWAR) byte tests: eight bytes in a `uint64`, loaded little-endian, each test
/// returning the high bit of every byte that matches (exactly, with no false positives, so the result
/// can be counted). The union of XmlBeef's XmlChar and JsonBeef's JsonChar primitives. Every member is
/// `[Inline]`: a literal argument (`Swar.BytesEqual(w, (uint8)'<')`) folds to an immediate in the
/// caller's loop.
internal static class Swar
{
	/// @brief 0x01 in every byte.
	public const uint64 Ones = 0x0101010101010101UL;
	/// @brief 0x80 in every byte.
	public const uint64 High = 0x8080808080808080UL;

	/// @brief The 8 bytes at `p` (unaligned).
	/// @param p The first byte.
	/// @return The bytes as a little-endian word.
	[Inline]
	public static uint64 Load64(char8* p)
	{
		uint64 word = ?;
		Internal.MemCpy(&word, p, 8);
		return word;
	}

	/// @brief The 4 bytes at `p` (unaligned).
	/// @param p The first byte.
	/// @return The bytes as a little-endian word.
	[Inline]
	public static uint32 Load32(char8* p)
	{
		uint32 word = ?;
		Internal.MemCpy(&word, p, 4);
		return word;
	}

	/// @brief The high bit of each zero byte of `x`.
	/// @param x The word.
	/// @return The mask.
	[Inline]
	public static uint64 ZeroBytes(uint64 x)
	{
		const uint64 low7 = 0x7F7F7F7F7F7F7F7FUL;
		return ~(((x & low7) + low7) | x | low7);
	}

	/// @brief The high bit of each byte of `word` that equals `c`.
	/// @param word The word.
	/// @param c The byte to find.
	/// @return The mask.
	[Inline]
	public static uint64 BytesEqual(uint64 word, uint8 c)
	{
		return ZeroBytes(word ^ ((uint64)c * Ones));
	}

	/// @brief The high bit of each byte of `word` below 0x20 (bytes ≥ 0x80 excepted).
	/// @param word The word.
	/// @return The mask.
	[Inline]
	public static uint64 BytesBelowSpace(uint64 word)
	{
		// Adding 0x60 to a byte below 0x80 sets its high bit when it is at least 0x20
		return ~((word & ~High) + 0x6060606060606060UL) & ~word & High;
	}

	/// @brief The high bit of each byte of `word` above 0x20 (a space): bytes ≥ 0x80 included.
	/// @param word The word.
	/// @return The mask.
	[Inline]
	public static uint64 BytesAboveSpace(uint64 word)
	{
		// Adding 0x5F to a byte below 0x80 sets its high bit when it is at least 0x21
		return (word | ((word & ~High) + 0x5F5F5F5F5F5F5F5FUL)) & High;
	}

	/// @brief Nonzero when `word` has a byte below 0x0E (exact as to whether there is one, not as to
	/// which: a byte just above one that is may be marked too). Text without one holds no LF or CR.
	/// @param word The word.
	/// @return The mask.
	[Inline]
	public static uint64 BytesBelow0E(uint64 word)
	{
		return (word - 0x0E0E0E0E0E0E0E0EUL) & ~word & High;
	}

	/// @brief The high bit of each byte of `word` that is not a space, tab, LF or CR.
	/// @param word The word.
	/// @return The mask.
	[Inline]
	public static uint64 NonSpaceBytes(uint64 word)
	{
		return ~(BytesEqual(word, (uint8)' ') | BytesEqual(word, (uint8)'\n') | BytesEqual(word, (uint8)'\r') | BytesEqual(word, (uint8)'\t')) & High;
	}

	/// @brief Whether the 8 bytes of `word` are all ASCII (below 0x80).
	/// @param word The word.
	/// @return Whether they are.
	[Inline]
	public static bool IsAscii(uint64 word)
	{
		return (word & High) == 0;
	}

	/// @brief Whether the 8 bytes of `word` are all ASCII digits.
	/// @param word The word.
	/// @return Whether they are.
	[Inline]
	public static bool AllDigits(uint64 word)
	{
		return ((word & 0xF0F0F0F0F0F0F0F0UL) | (((word + 0x0606060606060606UL) & 0xF0F0F0F0F0F0F0F0UL) >> 4)) == 0x3333333333333333UL;
	}

	/// @brief The value of 8 ASCII digits loaded little-endian (the first digit in the lowest byte):
	/// pairs, then quads, then the whole, in three multiplies (simdjson's parse_eight_digits_unrolled).
	/// @param word Eight digits (`AllDigits`).
	/// @return Their value, 0-99,999,999.
	[Inline]
	public static uint64 ParseEightDigits(uint64 word)
	{
		uint64 value = word - 0x3030303030303030UL;
		value = (value * 10) + (value >> 8);
		value = (((value & 0x000000FF000000FFUL) * (100 + (1000000UL << 32))) +
			(((value >> 16) & 0x000000FF000000FFUL) * (1 + (10000UL << 32)))) >> 32;
		return value & 0xFFFFFFFFUL;
	}

	/// @brief The number of bytes of `mask` whose high bit is set (no other bits may be).
	/// @param mask A mask of high bits.
	/// @return 0-8.
	[Inline]
	public static int CountHighBits(uint64 mask)
	{
		return (int)(((mask >> 7) * Ones) >> 56);
	}

	/// @brief The index (0-7) of the lowest byte whose high bit is set in `mask`, which must be nonzero
	/// and have no other bits: the bytes below it, counted (Beef reaches no trailing-zero count).
	/// @param mask A nonzero mask of high bits.
	/// @return The index.
	[Inline]
	public static int FirstByte(uint64 mask)
	{
		return CountHighBits(((mask & (~mask + 1)) - 1) & High);
	}

	/// @brief Whether `a[0 ..< length]` equals `b[0 ..< length]`: word compares (overlapping at the
	/// end), no call.
	/// @param a The first bytes.
	/// @param b The second bytes.
	/// @param length How many to compare.
	/// @return Whether they are equal.
	[Inline]
	public static bool EqualBytes(char8* a, char8* b, int length)
	{
		if (length >= 8)
		{
			int i = 0;
			while (i + 8 < length)
			{
				if (Load64(a + i) != Load64(b + i))
					return false;
				i += 8;
			}
			return Load64(a + length - 8) == Load64(b + length - 8);
		}
		if (length >= 4)
			return Load32(a) == Load32(b) && Load32(a + length - 4) == Load32(b + length - 4);
		for (int i < length)
		{
			if (a[i] != b[i])
				return false;
		}
		return true;
	}
}

/// 16 comparison results (0 or 1 per byte): a vector LLVM keeps in an SSE register (JsonBeef's
/// JsonMask16).
[UnderlyingArray(typeof(bool), 16, true)]
internal struct Mask16
{
	// The layout as two words (without fields the compiler crashes emitting debug info for a local)
	public uint64 mLow;
	public uint64 mHigh;

	/// @brief Lane-wise or.
	[Intrinsic("or")]
	public static extern Mask16 operator|(Mask16 a, Mask16 b);

	/// @brief The index (0-15) of the first lane that is set, or 16 when none is.
	/// @return The index.
	[Inline]
	public int FirstSet() mut
	{
		uint64* words = (uint64*)&this;
		uint64 low = words[0];
		uint64 high = words[1];
		if ((low | high) == 0)
			return 16;
		// Lanes are 0 or 1: moved to each byte's high bit for FirstByte
		if (low != 0)
			return Swar.FirstByte(low << 7);
		return 8 + Swar.FirstByte(high << 7);
	}
}

/// 16 bytes as signed lanes, compared lane by lane with pcmpeqb/pcmpgtb (JsonBeef's JsonBytes16).
/// SSE2's byte compare is signed: bytes ≥ 0x80 are below 0x20 too, which a string scan wants.
[UnderlyingArray(typeof(int8), 16, true)]
internal struct Bytes16
{
	public int64 mLow;
	public int64 mHigh;

	/// @brief Lane-wise equality.
	[Intrinsic("eq")]
	public static extern Mask16 operator==(Bytes16 a, Bytes16 b);
	/// @brief Lane-wise signed less-than.
	[Intrinsic("lt")]
	public static extern Mask16 operator<(Bytes16 a, Bytes16 b);

	/// @brief 16 copies of `value`.
	/// @param value The byte.
	/// @return The vector.
	[Inline]
	public static Bytes16 Splat(uint8 value)
	{
		uint64[2] words = .((uint64)value * Swar.Ones, (uint64)value * Swar.Ones);
		Bytes16 result = ?;
		Internal.MemCpy(&result, &words, 16);
		return result;
	}

	/// @brief The 16 bytes at `p` (unaligned).
	/// @param p The first byte.
	/// @return The vector.
	[Inline]
	public static Bytes16 Load(char8* p)
	{
		Bytes16 result = ?;
		Internal.MemCpy(&result, p, 16);
		return result;
	}
}
