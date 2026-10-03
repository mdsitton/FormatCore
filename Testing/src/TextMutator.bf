using System;
using System.Collections;

namespace FormatCore.Testing;

/// @brief The edits a TextMutator makes.
public enum MutationKind
{
	/// @brief Delete 1-8 bytes.
	DeleteRun,
	/// @brief Insert a token of the format's dictionary (`<!--`, `]]>`, `{`).
	InsertToken,
	/// @brief Copy a slice of 1-16 bytes somewhere else.
	DuplicateSlice,
	/// @brief Replace a byte by a token's first byte.
	ReplaceWithToken,
	/// @brief Replace a byte by a character of a random class (CharacterClass).
	ReplaceChar,
	/// @brief Insert a character of a random class.
	InsertChar
}

/// @brief The characters a mutation draws from (JsonTester's fuzz biases).
public enum CharacterClass
{
	/// @brief One of the format's interesting characters (structure, escapes, digits).
	Interesting,
	/// @brief Any byte.
	AnyByte,
	/// @brief A UTF-8 lead byte (0xC0-0xFF), invalid ones included.
	Utf8Lead,
	/// @brief A continuation byte (0x80-0xBF).
	Utf8Continuation,
	/// @brief Printable ASCII.
	PrintableAscii
}

/// @brief Seeded random edits of a document for fuzzing a reader (the union of XmlTester's byte
/// operators and JsonTester's character classes): the same seed gives the same edits, and the log says
/// what was done so a failure can be replayed or minimized by hand.
public class TextMutator
{
	Random mRandom ~ delete _;
	List<String> mTokens = new .() ~ DeleteContainerAndItems!(_);
	String mInteresting = new .() ~ delete _;
	/// @brief A line per edit since the last ClearLog (`insert "<!--" at 12`).
	public String mLog = new .() ~ delete _;

	/// @brief A mutator.
	/// @param seed The random seed.
	/// @param tokens The format's token dictionary (copied): markup, keywords, invalid bytes.
	/// @param interesting The format's interesting characters (bytes; copied).
	public this(int seed, Span<StringView> tokens, StringView interesting)
	{
		mRandom = new Random(seed);
		for (let token in tokens)
			mTokens.Add(new String(token));
		mInteresting.Set(interesting);
		if (mTokens.IsEmpty)
			mTokens.Add(new String(" "));
		if (mInteresting.IsEmpty)
			mInteresting.Set(" ");
	}

	/// @brief The generator (for choices the caller makes itself).
	public Random Random => mRandom;

	/// @brief Forget the log.
	public void ClearLog()
	{
		mLog.Clear();
	}

	/// @brief Make 1 to `maxEdits` random edits.
	/// @param text The document, edited in place.
	/// @param maxEdits The most edits.
	/// @return The number of edits made.
	public int Mutate(String text, int maxEdits = 4)
	{
		int edits = 1 + mRandom.Next(Math.Max(maxEdits, 1));
		for (int e < edits)
			Apply(text, (MutationKind)mRandom.Next(6));
		return edits;
	}

	/// @brief Mutate bytes (copied through a String).
	/// @param bytes The document, edited in place.
	/// @param maxEdits The most edits.
	/// @return The number of edits made.
	public int Mutate(List<uint8> bytes, int maxEdits = 4)
	{
		let text = scope String();
		text.Append((char8*)bytes.Ptr, bytes.Count);
		int edits = Mutate(text, maxEdits);
		bytes.Clear();
		bytes.AddRange(Span<uint8>((uint8*)text.Ptr, text.Length));
		return edits;
	}

	/// @brief A character of the class.
	/// @param kind The class.
	/// @return The byte.
	public char8 Character(CharacterClass kind)
	{
		switch (kind)
		{
		case .Interesting: return mInteresting[mRandom.Next(mInteresting.Length)];
		case .AnyByte: return (char8)mRandom.Next(256);
		case .Utf8Lead: return (char8)(0xC0 + mRandom.Next(0x40));
		case .Utf8Continuation: return (char8)(0x80 + mRandom.Next(0x40));
		case .PrintableAscii: return (char8)mRandom.Next(0x20, 0x7F);
		}
	}

	/// @brief Make one edit of the kind (a deletion, duplication or replacement of an empty text does
	/// nothing).
	/// @param text The document, edited in place.
	/// @param kind The edit.
	public void Apply(String text, MutationKind kind)
	{
		int count = text.Length;
		switch (kind)
		{
		case .DeleteRun:
			if (count == 0)
				return;
			int at = mRandom.Next(count);
			int length = Math.Min(1 + mRandom.Next(8), count - at);
			text.Remove(at, length);
			mLog.AppendF("delete {} bytes at {}\n", length, at);
		case .InsertToken:
			let token = mTokens[mRandom.Next(mTokens.Count)];
			int at = mRandom.Next(count + 1);
			text.Insert(at, token);
			mLog.AppendF("insert {} at {}\n", Quoted(token, .. scope .()), at);
		case .DuplicateSlice:
			if (count == 0)
				return;
			int from = mRandom.Next(count);
			int length = Math.Min(1 + mRandom.Next(16), count - from);
			let slice = scope String(text, from, length);
			int to = mRandom.Next(count + 1);
			text.Insert(to, slice);
			mLog.AppendF("copy {} bytes from {} to {}\n", length, from, to);
		case .ReplaceWithToken:
			if (count == 0)
				return;
			let token = mTokens[mRandom.Next(mTokens.Count)];
			int at = mRandom.Next(count);
			text[at] = token[0];
			mLog.AppendF("replace byte {} by 0x{:X2}\n", at, (uint8)token[0]);
		case .ReplaceChar:
			if (count == 0)
				return;
			char8 c = Character((CharacterClass)mRandom.Next(5));
			int at = mRandom.Next(count);
			text[at] = c;
			mLog.AppendF("replace byte {} by 0x{:X2}\n", at, (uint8)c);
		case .InsertChar:
			char8 c = Character((CharacterClass)mRandom.Next(5));
			int at = mRandom.Next(count + 1);
			text.Insert(at, c);
			mLog.AppendF("insert 0x{:X2} at {}\n", (uint8)c, at);
		}
	}

	/// @brief `text` in double quotes, with bytes outside printable ASCII as `\xHH`.
	/// @param text The text.
	/// @param output The string to append to.
	public static void Quoted(StringView text, String output)
	{
		output.Append('"');
		for (let c in text.RawChars)
		{
			if ((uint8)c >= 0x20 && (uint8)c < 0x7F && c != '"' && c != '\\')
				output.Append(c);
			else
				output.AppendF("\\x{:X2}", (uint8)c);
		}
		output.Append('"');
	}
}
