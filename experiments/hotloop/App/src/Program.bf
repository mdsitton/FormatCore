using System;
using Core;

namespace App;

/// The scan body, copied into App (the "all in App" control).
static class AppScan
{
	const uint64 Ones = 0x0101010101010101UL;
	const uint64 High = 0x8080808080808080UL;

	/// (a-type): an ordinary method of another App type (another module, same project).
	public static int Scan(uint8* data, int pos, int end)
	{
		return Body(data, pos, end);
	}

	/// (a-inline): the App counterpart of (d).
	[Inline]
	public static int ScanInline(uint8* data, int pos, int end)
	{
		return Body(data, pos, end);
	}

	[Inline]
	public static int Body(uint8* data, int pos, int end)
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

	/// (e-app): the App-local form of the table-driven scan (the control for the e-* modes).
	public static int ScanTable(uint8* data, int pos, int end)
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
			if (AppStops.cTable[data[p]] != 0)
				return p;
			p++;
		}
		return end;
	}
}

/// (c): an App cursor (ordinary Scan) plugged into Core's generic reader.
struct AppCursor : ICursor
{
	public int Scan(uint8* data, int pos, int end) => AppScan.Body(data, pos, end);
}

/// (c-inline): the same with an [Inline] Scan.
struct AppCursorInline : ICursor
{
	[Inline]
	public int Scan(uint8* data, int pos, int end) => AppScan.Body(data, pos, end);
}

/// (c-mono): an App copy of ReaderCore (the control for c).
struct AppReader<TCursor> where TCursor : ICursor
{
	public TCursor mCursor;

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

/// The App-owned stop set: '<', '&' and bytes below 0x20, classified through a const table.
struct AppStops : IStopSet
{
	public static uint8[256] sTable = BuildTable();
	public const uint8[256] cTable = BuildTable();

	public static uint8[256] BuildTable()
	{
		uint8[256] t = default;
		for (int i < 0x20)
			t[i] = 1;
		t['<'] = 1;
		t['&'] = 1;
		return t;
	}

	public static uint8 S1 => (uint8)'<';
	public static uint8 S2 => (uint8)'&';
	public static bool IsStop(uint8 b) => cTable[b] != 0;
}

/// The same stop set classified through a static (mutable) table.
struct AppStopsStatic : IStopSet
{
	public static uint8 S1 => (uint8)'<';
	public static uint8 S2 => (uint8)'&';
	public static bool IsStop(uint8 b) => AppStops.sTable[b] != 0;
}

/// The const-table stop set with [Inline] static members (for builds without LTO).
struct AppStopsInline : IStopSet
{
	public static uint8 S1
	{
		[Inline] get => (uint8)'<';
	}
	public static uint8 S2
	{
		[Inline] get => (uint8)'&';
	}
	[Inline]
	public static bool IsStop(uint8 b) => AppStops.cTable[b] != 0;
}

class Program
{
	/// (a-same): the scan in the same type as the loop.
	static int ScanLocal(uint8* data, int pos, int end)
	{
		return AppScan.Body(data, pos, end);
	}

	// Each pass is [NoInline] so its loop can be read in isolation with objdump
	[NoInline]
	static int PassSame(uint8* data, int end)
	{
		int count = 0, pos = 0;
		while (true) { pos = ScanLocal(data, pos, end); if (pos >= end) break; count++; pos++; }
		return count;
	}

	[NoInline]
	static int PassType(uint8* data, int end)
	{
		int count = 0, pos = 0;
		while (true) { pos = AppScan.Scan(data, pos, end); if (pos >= end) break; count++; pos++; }
		return count;
	}

	[NoInline]
	static int PassAppInline(uint8* data, int end)
	{
		int count = 0, pos = 0;
		while (true) { pos = AppScan.ScanInline(data, pos, end); if (pos >= end) break; count++; pos++; }
		return count;
	}

	[NoInline]
	static int PassCore(uint8* data, int end)
	{
		int count = 0, pos = 0;
		while (true) { pos = CoreScan.Scan(data, pos, end); if (pos >= end) break; count++; pos++; }
		return count;
	}

	[NoInline]
	static int PassCoreInline(uint8* data, int end)
	{
		int count = 0, pos = 0;
		while (true) { pos = CoreScan.ScanInline(data, pos, end); if (pos >= end) break; count++; pos++; }
		return count;
	}

	[NoInline]
	static int PassGeneric(uint8* data, int end) => ReaderCore<AppCursor>(.()).CountStops(data, end);

	[NoInline]
	static int PassGenericInline(uint8* data, int end) => ReaderCore<AppCursorInline>(.()).CountStops(data, end);

	[NoInline]
	static int PassMono(uint8* data, int end) => AppReader<AppCursor>().CountStops(data, end);

	[NoInline]
	static int PassMonoInline(uint8* data, int end) => AppReader<AppCursorInline>().CountStops(data, end);

	[NoInline]
	static int PassApp(uint8* data, int end)
	{
		int count = 0, pos = 0;
		while (true) { pos = AppScan.ScanTable(data, pos, end); if (pos >= end) break; count++; pos++; }
		return count;
	}

	[NoInline]
	static int PassConst(uint8* data, int end)
	{
		int count = 0, pos = 0;
		while (true) { pos = CoreScan.ScanConst<const '<', const '&'>(data, pos, end); if (pos >= end) break; count++; pos++; }
		return count;
	}

	[NoInline]
	static int PassStatic(uint8* data, int end) => StopScanner<AppStops>.CountStops(data, end);

	[NoInline]
	static int PassStaticInline(uint8* data, int end) => StopScanner<AppStopsInline>.CountStops(data, end);

	[NoInline]
	static int PassStaticTable(uint8* data, int end) => StopScanner<AppStopsStatic>.CountStops(data, end);

	[NoInline]
	static int PassParam(uint8* data, int end)
	{
		int count = 0, pos = 0;
		uint8* table = &AppStops.sTable;
		while (true) { pos = CoreScan.ScanParam(data, pos, end, (.)'<', (.)'&', table); if (pos >= end) break; count++; pos++; }
		return count;
	}

	[NoInline]
	static int PassParamInline(uint8* data, int end)
	{
		int count = 0, pos = 0;
		uint8* table = &AppStops.sTable;
		while (true) { pos = CoreScan.ScanParamInline(data, pos, end, (.)'<', (.)'&', table); if (pos >= end) break; count++; pos++; }
		return count;
	}

	public static int Main(String[] args)
	{
		if (args.Count < 2)
		{
			Console.WriteLine("usage: App <mode> <iterations>");
			return 1;
		}
		StringView mode = args[0];
		int iterations = int.Parse(args[1]).GetValueOrDefault();

		// 100 MiB: letters, '<' every 61 bytes, '\n' every 997 bytes
		const int size = 100 * 1024 * 1024;
		uint8* data = new uint8[size]*;
		defer delete data;
		for (int i < size)
			data[i] = (i % 997 == 996) ? (uint8)'\n' : (i % 61 == 60) ? (uint8)'<' : (uint8)('a' + i % 26);

		int total = 0;
		for (int it < iterations)
		{
			switch (mode)
			{
			case "a-same": total += PassSame(data, size);
			case "a-type": total += PassType(data, size);
			case "a-inline": total += PassAppInline(data, size);
			case "b": total += PassCore(data, size);
			case "d": total += PassCoreInline(data, size);
			case "c": total += PassGeneric(data, size);
			case "c-inline": total += PassGenericInline(data, size);
			case "c-mono": total += PassMono(data, size);
			case "c-mono-inline": total += PassMonoInline(data, size);
			case "e-app": total += PassApp(data, size);
			case "e-const": total += PassConst(data, size);
			case "e-static": total += PassStatic(data, size);
			case "e-static-inline": total += PassStaticInline(data, size);
			case "e-static-table": total += PassStaticTable(data, size);
			case "e-param": total += PassParam(data, size);
			case "e-param-inline": total += PassParamInline(data, size);
			default:
				Console.WriteLine("unknown mode");
				return 1;
			}
		}
		Console.WriteLine(total);
		return 0;
	}
}
