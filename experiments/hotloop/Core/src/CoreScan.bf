using System;

namespace Core;

/// The SWAR stop-byte scan, owned by the library. Stops at '<', '&' and bytes below 0x20.
public static class CoreScan
{
	public const uint64 Ones = 0x0101010101010101UL;
	public const uint64 High = 0x8080808080808080UL;

	/// (b): an ordinary (not [Inline]) static method in Core, called from App.
	public static int Scan(uint8* data, int pos, int end)
	{
		return ScanBody(data, pos, end);
	}

	/// (d): the same body, [Inline], called from App.
	[Inline]
	public static int ScanInline(uint8* data, int pos, int end)
	{
		return ScanBody(data, pos, end);
	}

	[Inline]
	static int ScanBody(uint8* data, int pos, int end)
	{
		int p = pos;
		while (p + 8 <= end)
		{
			uint64 word = ?;
			Internal.MemCpy(&word, data + p, 8);
			uint64 below = (word - 0x20 * Ones) & ~word;
			uint64 x1 = word ^ ((uint64)'<' * Ones);
			uint64 x2 = word ^ ((uint64)'&' * Ones);
			if (((below | ((x1 - Ones) & ~x1) | ((x2 - Ones) & ~x2)) & High) != 0)
				break;
			p += 8;
		}
		while (p < end)
		{
			uint8 b = data[p];
			if (b < 0x20 || b == '<' || b == '&')
				return p;
			p++;
		}
		return end;
	}

	/// (e-param): stop bytes and the byte-class table as runtime arguments, not inlined.
	public static int ScanParam(uint8* data, int pos, int end, uint8 s1, uint8 s2, uint8* table)
	{
		return ScanParamBody(data, pos, end, s1, s2, table);
	}

	/// (e-param-inline): the same, [Inline]: constants at the call site propagate into the body.
	[Inline]
	public static int ScanParamInline(uint8* data, int pos, int end, uint8 s1, uint8 s2, uint8* table)
	{
		return ScanParamBody(data, pos, end, s1, s2, table);
	}

	[Inline]
	static int ScanParamBody(uint8* data, int pos, int end, uint8 s1, uint8 s2, uint8* table)
	{
		uint64 m1 = s1 * Ones;
		uint64 m2 = s2 * Ones;
		int p = pos;
		while (p + 8 <= end)
		{
			uint64 word = ?;
			Internal.MemCpy(&word, data + p, 8);
			uint64 below = (word - 0x20 * Ones) & ~word;
			uint64 x1 = word ^ m1;
			uint64 x2 = word ^ m2;
			if (((below | ((x1 - Ones) & ~x1) | ((x2 - Ones) & ~x2)) & High) != 0)
				break;
			p += 8;
		}
		// The byte loop classifies through the table (as the real scanners do)
		while (p < end)
		{
			if (table[data[p]] != 0)
				return p;
			p++;
		}
		return end;
	}

	/// (e-const): stop bytes as const generic parameters.
	public static int ScanConst<S1, S2>(uint8* data, int pos, int end) where S1 : const uint8 where S2 : const uint8
	{
		const uint64 m1 = S1 * Ones;
		const uint64 m2 = S2 * Ones;
		int p = pos;
		while (p + 8 <= end)
		{
			uint64 word = ?;
			Internal.MemCpy(&word, data + p, 8);
			uint64 below = (word - 0x20 * Ones) & ~word;
			uint64 x1 = word ^ m1;
			uint64 x2 = word ^ m2;
			if (((below | ((x1 - Ones) & ~x1) | ((x2 - Ones) & ~x2)) & High) != 0)
				break;
			p += 8;
		}
		while (p < end)
		{
			uint8 b = data[p];
			if (b < 0x20 || b == S1 || b == S2)
				return p;
			p++;
		}
		return end;
	}
}
