using System;
using internal FormatCore;

namespace FormatCore;

/// A set of stop bytes for Scan.Until, at compile time: the format's struct implements both tests and
/// passes itself as a generic argument, so the masks fold to immediates in the specialized loop.
/// Mark both members `[Inline]`.
internal interface IStopSet
{
	/// The high bit of each byte of `word` that is a stop (exactly: no false positives).
	static uint64 Word(uint64 word);

	/// Whether the byte `b` is a stop (the tail loop's test; must agree with Word).
	static bool Byte(uint8 b);
}

/// A 16-byte stop set for Scan.Until16 (SSE2 compares): the lanes that stop.
internal interface IStopSet16 : IStopSet
{
	/// The lanes of `bytes` that are stops.
	static Mask16 Lanes(Bytes16 bytes);
}

/// Scans for the first stop byte. The refill-and-resume loop around a scan stays in each reader core
/// (it needs the core's Grow): these take the window as locals and return a position, never touching
/// the caller's state (KdlBeef measured 25% from storing the position per byte).
internal static class Scan
{
	/// @brief The first offset in `[p, end)` whose byte is a stop, or `end`: 8 bytes at a time, then
	/// a byte at a time.
	/// @param data The window, indexed by absolute offsets.
	/// @param p Where to start.
	/// @param end The end of the window.
	/// @return The stop's offset, or `end`.
	[Inline]
	public static int Until<TStops>(char8* data, int p, int end) where TStops : IStopSet
	{
		var p;
		while (p + 8 <= end)
		{
			uint64 stops = TStops.Word(Swar.Load64(data + p));
			if (stops != 0)
				return p + Swar.FirstByte(stops);
			p += 8;
		}
		while (p < end && !TStops.Byte((uint8)data[p]))
			p++;
		return p;
	}

	/// @brief Until with 16-byte vector compares first (paid for JSON strings, not for whitespace:
	/// choose per call site).
	/// @param data The window, indexed by absolute offsets.
	/// @param p Where to start.
	/// @param end The end of the window.
	/// @return The stop's offset, or `end`.
	[Inline]
	public static int Until16<TStops>(char8* data, int p, int end) where TStops : IStopSet16
	{
		var p;
		while (p + 16 <= end)
		{
			var lanes = TStops.Lanes(Bytes16.Load(data + p));
			int first = lanes.FirstSet();
			if (first < 16)
				return p + first;
			p += 16;
		}
		return Until<TStops>(data, p, end);
	}
}
