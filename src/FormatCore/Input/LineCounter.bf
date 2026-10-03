using System;
using internal FormatCore;

namespace FormatCore;

/// Counts lines forward through the input, and columns only when asked (XmlBeef's XmlLineCounter,
/// generalized over the format's newlines): newlines are found 16 and 8 bytes at a time up to an
/// offset (AdvanceLines), and a column is the code points from a base on the current line (its start,
/// or a later offset whose column is known) to the offset. CRLF is one newline; an offset inside a
/// multi-byte newline (on the LF of a CRLF) is on the line the newline ends, after its first byte.
internal struct LineCounter<TText> where TText : ITextPolicy
{
	/// Newlines are counted up to here.
	public int mPos;
	public int mLine = 1;
	/// The column base: an offset on the current line (its start, or later) and its column.
	public int mLineStart;
	public int mLineColumn = 1;

	/// @brief A counter at line 1, column 1 at `start` (after a BOM).
	/// @param start The offset of the first content byte.
	public this(int start)
	{
		mPos = start;
		mLineStart = start;
	}

	/// @brief Moves to `offset` (not before the current position), counting every newline.
	/// `text[mPos ..< offset]` must be available, up to `end`.
	/// @param text The bytes, indexed by absolute offsets.
	/// @param offset Where to move.
	/// @param end The end of the available bytes (at or after `offset`).
	public void AdvanceLines(char8* text, int offset, int end) mut
	{
		while (mPos < offset)
		{
			// Two words at a time while neither may hold a newline
			while (mPos + 16 <= offset && (TText.MayHoldNewline(Swar.Load64(text + mPos)) | TText.MayHoldNewline(Swar.Load64(text + mPos + 8))) == 0)
				mPos += 16;
			if (mPos >= offset)
				break;
			if (TText.OnlyAsciiNewlines && mPos + 8 <= end)
			{
				// Every newline of the word at once: each LF, and each CR not followed by an LF (in the word,
				// or the next byte). A word past `offset` (still in the window) counts only the bytes before it.
				int count = Math.Min(offset - mPos, 8);
				uint64 word = Swar.Load64(text + mPos);
				uint64 lf = Swar.BytesEqual(word, (uint8)'\n');
				uint64 cr = Swar.BytesEqual(word, (uint8)'\r');
				if ((lf | cr) != 0)
				{
					uint64 lfNext = lf >> 8;
					if (mPos + 8 < end && text[mPos + 8] == '\n')
						lfNext |= 1UL << 63;
					uint64 newlines = lf | (cr & ~lfNext);
					if (count < 8)
						newlines &= (1UL << (count * 8)) - 1;
					if (newlines != 0)
					{
						mLine += Swar.CountHighBits(newlines);
						// The line starts after the last one: smeared down, its byte and those below
						uint64 below = newlines | (newlines >> 8);
						below |= below >> 16;
						below |= below >> 32;
						mLineStart = mPos + Swar.CountHighBits(below);
						mLineColumn = 1;
					}
				}
				mPos += count;
				continue;
			}
			if (!TText.OnlyAsciiNewlines && mPos + 8 <= offset && TText.MayHoldNewline(Swar.Load64(text + mPos)) == 0)
			{
				mPos += 8;
				continue;
			}
			int newline = TText.NewlineLength(text, mPos, end);
			// A newline across `offset` (an offset on the LF of a CRLF): not counted here; the rest of it
			// is counted from there
			if (mPos + newline > offset)
			{
				mPos = offset;
				break;
			}
			if (newline > 0)
			{
				mPos += newline;
				mLine++;
				mLineStart = mPos;
				mLineColumn = 1;
				continue;
			}
			mPos++;
		}
	}

	/// @brief The column of `offset`, which must be on the current line, at or after the base, with
	/// `text[mLineStart ..< offset]` available. The base moves there, so the next column on the line
	/// counts on from it. (An offset inside a newline, before the base, gets the base's column.)
	/// @param text The bytes, indexed by absolute offsets.
	/// @param offset The offset.
	/// @return The 1-based column in code points.
	public int Column(char8* text, int offset) mut
	{
		if (offset > mLineStart)
		{
			mLineColumn += Utf8.CountCodePoints(text, mLineStart, offset);
			mLineStart = offset;
		}
		return mLineColumn;
	}

	/// @brief AdvanceLines and Column: the line and column of `offset`.
	/// @param text The bytes, indexed by absolute offsets.
	/// @param offset The offset (not before the current position).
	/// @param end The end of the available bytes.
	/// @param line Receives the 1-based line.
	/// @param column Receives the 1-based column.
	public void Locate(char8* text, int offset, int end, out int line, out int column) mut
	{
		AdvanceLines(text, offset, end);
		line = mLine;
		column = Column(text, offset);
	}

	/// @brief Whether `offset` can be located from here (it is not behind the counter or its base).
	/// @param offset The offset.
	/// @return Whether it can.
	[Inline]
	public bool CanReach(int offset)
	{
		return offset >= mPos && offset >= mLineStart;
	}
}
