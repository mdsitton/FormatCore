using System;
using System.Collections;
using internal FormatCore;

namespace FormatCore.Tests;

enum ToyErrorKind : uint8
{
	UnexpectedChar,
	IoError
}

enum OtherErrorKind : uint8
{
	Broken
}

typealias ToyParseError = ParseError<ToyErrorKind>;
typealias ToyDiagnostic = Diagnostic<ToyErrorKind>;

static class DiagnosticsTests
{
	static Result<int, ToyParseError> Fails() => .Err(ToyParseError(.UnexpectedChar, "nope", 2, 3, 10, 1));

	static Result<int, ToyParseError> Propagates()
	{
		int value = Try!(Fails());
		return value;
	}

	[Test]
	public static void ParseError_FormatsAndPropagates()
	{
		let text = scope String();
		var error = ToyParseError(.UnexpectedChar, "Unexpected `x`", 3, 7, 42, 1);
		error.ToString(text);
		Test.Assert(text == "3:7: Unexpected `x`");
		error.SetSource("doc.toy");
		text.Clear();
		error.ToString(text);
		Test.Assert(text == "doc.toy:3:7: Unexpected `x`");
		error.PrependPath("/1");
		error.PrependPath("/items");
		text.Clear();
		error.ToString(text);
		Test.Assert(text == "doc.toy:3:7: /items/1: Unexpected `x`");
		let unlocated = ToyParseError(.IoError, "Reading failed", 0, 0, 0, 0);
		text.Clear();
		unlocated.ToString(text);
		Test.Assert(text == "Reading failed");

		Test.Assert(Propagates() case .Err(let propagated) && propagated.mKind == .UnexpectedChar && propagated.mMessage == "nope");
		let at = ToyParseError.At<PlainUtf8Text>(.UnexpectedChar, "here", "ab\ncd", 4);
		Test.Assert(at.mLine == 2 && at.mColumn == 2 && at.mOffset == 4);
	}

	[Test]
	public static void ParseError_BuffersAreKeptApart()
	{
		// A message rebuilt from the previous error's message (a view of the same buffer)
		let first = ToyParseError(.UnexpectedChar, "first message", 1, 1, 0);
		let rebuilt = ToyParseError(.UnexpectedChar, first.mMessage.Substring(6), 1, 1, 0);
		Test.Assert(rebuilt.mMessage == "message");
		// Another error-kind type has its own buffers
		let toy = ToyParseError(.UnexpectedChar, "toy", 1, 1, 0);
		let other = ParseError<OtherErrorKind>(.Broken, "other", 1, 1, 0);
		Test.Assert(toy.mMessage == "toy" && other.mMessage == "other");
		// An input error converts by copying its message
		let input = InputError(.InvalidUtf8, "bad bytes", 1, 2, 1, 1);
		let converted = ToyParseError(.UnexpectedChar, input.mMessage, input.mLine, input.mColumn, input.mOffset, input.mLength);
		Test.Assert(converted.mMessage == "bad bytes");
	}

	[Test]
	public static void Diagnostic_KeepsItsText()
	{
		var error = ToyParseError(.UnexpectedChar, "kept", 4, 5, 6, 2);
		error.SetSource("a.toy");
		error.PrependPath("/k");
		let kept = scope ToyDiagnostic(error);
		// The next error replaces the per-thread text; the diagnostic keeps its own
		let next = ToyParseError(.IoError, "next", 1, 1, 0);
		Test.Assert(next.mMessage == "next" && kept.mMessage == "kept");
		let text = scope String();
		kept.ToString(text);
		Test.Assert(text == "a.toy:4:5: /k: kept");
		var restored = kept.Error;
		Test.Assert(restored.mMessage.Ptr == kept.mMessage.Ptr && restored.mLength == 2);
		// Detached, it outlives the diagnostic's strings
		restored.Detach();
		Test.Assert(restored.mMessage.Ptr != kept.mMessage.Ptr && restored.mMessage == "kept" && restored.mSource == "a.toy" && restored.mPath == "/k");
		// A path prepended to a diagnostic's path
		var fromKept = kept.Error;
		fromKept.PrependPath("/outer");
		Test.Assert(fromKept.mPath == "/outer/k" && kept.mPath == "/k");
	}

	[Test]
	public static void ErrorPolicy_StopsAndMakesProgress()
	{
		var policy = ErrorPolicy(false, 0);
		Test.Assert(policy.ShouldStop(false));
		policy = ErrorPolicy(true, 3);
		Test.Assert(!policy.ShouldStop(false) && policy.ShouldStop(true));
		Test.Assert(!policy.ShouldStop(false));
		Test.Assert(policy.ShouldStop(false));
		policy = ErrorPolicy(true, 0);
		for (int i < 1000)
			Test.Assert(!policy.ShouldStop(false));
		Test.Assert(policy.Anchor(10) == 10 && policy.Anchor(10) == 11 && policy.Anchor(5) == 12 && policy.Anchor(20) == 20);
		Test.Assert(Limits.Exceeds(10, 11) && !Limits.Exceeds(10, 10) && !Limits.Exceeds(0, 1000));
		let message = scope String();
		Limits.AppendExceeded(message, "The nesting depth", "MaxDepth", 256);
		Test.Assert(message == "The nesting depth exceeds MaxDepth (256)");
	}

	[Test]
	public static void RangeRecord_States()
	{
		RangeRecord none = default;
		Test.Assert(!none.HasRange);
		let pending = RangeRecord(-1, 0, 12, 3);
		Test.Assert(pending.HasRange && pending.NeedsLocating);
		let located = RangeRecord(2, 4, 12, 3);
		Test.Assert(located.HasRange && !located.NeedsLocating && located.mOffset == 12);
	}
}
