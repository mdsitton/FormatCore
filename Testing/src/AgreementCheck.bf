using System;
using System.Collections;

namespace FormatCore.Testing;

/// @brief Reads one input several ways (named modes: memory, a 1-byte stream, collect-errors, a fast
/// path) and checks that every mode's outcome text equals the first mode's: the differential test the
/// format libraries' fuzzers run (JsonTester's Agree, XmlTester's memory/stream comparison). A mode
/// appends its outcome to the string it is given: a canonical form when the input is accepted, the
/// error (kind, line, column, offset) when it is not.
public class AgreementCheck
{
	/// @brief One way of reading an input: append the outcome.
	public delegate void Mode(StringView input, String outcome);

	List<String> mNames = new .() ~ DeleteContainerAndItems!(_);
	List<Mode> mModes = new .() ~ DeleteContainerAndItems!(_);

	/// @brief The first mode that disagreed in the last Run (empty when all agreed).
	public String mMode = new .() ~ delete _;
	/// @brief The reference mode's line where they first differ, and the disagreeing mode's.
	public String mExpected = new .() ~ delete _;
	public String mActual = new .() ~ delete _;
	/// @brief The line number (1-based) of that difference.
	public int mLine;

	/// @brief Add a mode; the first one added is the reference.
	/// @param name The mode's name (copied).
	/// @param mode The mode (owned by the check from now on).
	public void Add(StringView name, Mode mode)
	{
		mNames.Add(new String(name));
		mModes.Add(mode);
	}

	/// @brief The number of modes.
	public int Count => mModes.Count;

	/// @brief Run every mode over `input`.
	/// @param input The input.
	/// @return Whether all agree with the reference (otherwise mMode, mLine, mExpected and mActual say
	/// where they first differ).
	public bool Run(StringView input)
	{
		mMode.Clear();
		mExpected.Clear();
		mActual.Clear();
		mLine = 0;
		if (mModes.IsEmpty)
			return true;
		let reference = scope String();
		mModes[0](input, reference);
		let outcome = scope String();
		for (int i = 1; i < mModes.Count; i++)
		{
			outcome.Clear();
			mModes[i](input, outcome);
			if (outcome == reference)
				continue;
			mMode.Set(mNames[i]);
			FirstDifference(reference, outcome);
			return false;
		}
		return true;
	}

	void FirstDifference(StringView expected, StringView actual)
	{
		var linesA = expected.Split('\n');
		var linesB = actual.Split('\n');
		int line = 0;
		while (true)
		{
			line++;
			let a = linesA.GetNext();
			let b = linesB.GetNext();
			StringView x = (a case .Ok(let va)) ? va : "(end)";
			StringView y = (b case .Ok(let vb)) ? vb : "(end)";
			if (x != y || (a case .Err && b case .Err))
			{
				mLine = line;
				mExpected.Set(x);
				mActual.Set(y);
				return;
			}
		}
	}

	/// @brief Append the report of the last disagreement: `<mode> differs from <reference> at line N:`
	/// and the two lines.
	/// @param output The string to append to.
	public void Report(String output)
	{
		if (mMode.IsEmpty)
			return;
		output.AppendF("{} differs from {} at line {}:\n", mMode, mNames[0], mLine);
		output.AppendF("  {}: {}\n", mNames[0], mExpected);
		output.AppendF("  {}: {}\n", mMode, mActual);
	}
}
