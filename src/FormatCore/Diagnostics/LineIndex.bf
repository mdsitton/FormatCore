using System;
using internal FormatCore;

namespace FormatCore;

/// The line starts of a kept source, built on the first request, for locating offsets of a document
/// read from memory without counting while reading (XmlBeef's and JsonBeef's mLineStarts). Lines end at
/// the policy's newlines (CRLF as one); columns are code points; a leading BOM takes no column; an
/// offset inside a multi-byte newline is on the line it ends.
internal class LineIndex<TText> where TText : ITextPolicy
{
	GrowList<int> mStarts ~ delete _;
	bool mBuilt;

	public this()
	{
		mStarts = new .();
	}

	/// @brief Forget the index (the source changed).
	public void Clear()
	{
		mStarts.Clear();
		mBuilt = false;
	}

	/// @brief Whether the index has been built since the last Clear.
	public bool IsBuilt => mBuilt;

	/// @brief The bytes the index holds.
	public int ReservedBytes => mStarts.ReservedBytes;

	void Build(char8* source, int length)
	{
		mStarts.Clear();
		mStarts.Add(Utf8.StartsWithBom(source, length) ? 3 : 0);
		int i = 0;
		while (i < length)
		{
			if (i + 8 <= length && TText.MayHoldNewline(Swar.Load64(source + i)) == 0)
			{
				i += 8;
				continue;
			}
			int newline = TText.NewlineLength(source, i, length);
			if (newline > 0)
			{
				i += newline;
				mStarts.Add(i);
				continue;
			}
			i++;
		}
		mBuilt = true;
	}

	/// @brief The line and column of `offset` in `source` (the same source every time until Clear).
	/// @param source The kept source.
	/// @param length Its length.
	/// @param offset A byte offset into it (clamped to the length).
	/// @param line Receives the 1-based line.
	/// @param column Receives the 1-based column in code points.
	public void Locate(char8* source, int length, int offset, out int line, out int column)
	{
		if (!mBuilt)
			Build(source, length);
		int target = Math.Clamp(offset, 0, length);
		// The last line start at or before the offset
		int low = 0;
		int high = mStarts.Count - 1;
		while (low < high)
		{
			int mid = (low + high + 1) / 2;
			if (mStarts[mid] <= target)
				low = mid;
			else
				high = mid - 1;
		}
		line = low + 1;
		int start = mStarts[low];
		column = Utf8.CountCodePoints(source, start, Math.Max(target, start)) + 1;
	}
}

/// One stored source range: line 0 means none; line -1 means offsets only, located on request
/// (LineIndex). Positions are 32-bit (a document over 2 GiB stores no positions: plan.md §9 Q6).
internal struct RangeRecord
{
	public int32 mLine;
	public int32 mColumn;
	public int32 mOffset;
	public int32 mLength;

	public this(int line, int column, int offset, int length)
	{
		mLine = (int32)line;
		mColumn = (int32)column;
		mOffset = (int32)offset;
		mLength = (int32)length;
	}

	/// @brief Whether there is a range.
	public bool HasRange => mLine != 0;

	/// @brief Whether the line and column are still to be located.
	public bool NeedsLocating => mLine < 0;
}
