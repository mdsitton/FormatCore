using System;

namespace Core;

/// A cursor the consumer supplies (an App struct).
public interface ICursor
{
	int Scan(uint8* data, int pos, int end);
}

/// A stop set the consumer supplies through static interface members.
public interface IStopSet
{
	static uint8 S1 { get; }
	static uint8 S2 { get; }
	static bool IsStop(uint8 b);
}

/// (c): a generic in Core whose hot loop calls the App cursor's Scan.
public struct ReaderCore<TCursor> where TCursor : ICursor
{
	public TCursor mCursor;

	public this(TCursor cursor)
	{
		mCursor = cursor;
	}

	public int CountStops(uint8* data, int end) mut
	{
		int count = 0;
		int pos = 0;
		while (true)
		{
			pos = mCursor.Scan(data, pos, end);
			if (pos >= end)
				break;
			count++;
			pos++;
		}
		return count;
	}
}

/// (e-static): a generic in Core whose stop set (SWAR constants and byte-class table) comes from the
/// App type's static interface members.
public static class StopScanner<TStops> where TStops : IStopSet
{
	public static int CountStops(uint8* data, int end)
	{
		int count = 0;
		int pos = 0;
		while (true)
		{
			pos = Scan(data, pos, end);
			if (pos >= end)
				break;
			count++;
			pos++;
		}
		return count;
	}

	[Inline]
	static int Scan(uint8* data, int pos, int end)
	{
		const uint64 ones = CoreScan.Ones;
		uint64 m1 = TStops.S1 * ones;
		uint64 m2 = TStops.S2 * ones;
		int p = pos;
		while (p + 8 <= end)
		{
			uint64 word = ?;
			Internal.MemCpy(&word, data + p, 8);
			uint64 below = (word - 0x20 * ones) & ~word;
			uint64 x1 = word ^ m1;
			uint64 x2 = word ^ m2;
			if (((below | ((x1 - ones) & ~x1) | ((x2 - ones) & ~x2)) & CoreScan.High) != 0)
				break;
			p += 8;
		}
		while (p < end)
		{
			if (TStops.IsStop(data[p]))
				return p;
			p++;
		}
		return end;
	}
}
