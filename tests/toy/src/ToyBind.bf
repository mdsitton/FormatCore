using System;
using System.Collections;
using FormatCore;

namespace ToyFormat;

/// The toy format's binding errors.
public enum ToyErrorKind : uint8
{
	/// A value of another kind than the field needs.
	TypeMismatch,
	/// A number outside the field's range.
	OutOfRange,
	/// A [ToyRequired] member is absent.
	MissingValue,
	/// An unknown enum case, or a converter's rejection.
	InvalidValue
}

/// The toy format's error: FormatCore's carrier under the format's name.
public typealias ToyError = FormatCore.ParseError<ToyErrorKind>;

/// What the generated code calls for each value (the toy counterpart of JsonBind and XmlBind).
public static class ToyBind
{
	static ToyError Mismatch(ToyNode node, StringView expected)
	{
		return ToyError(.TypeMismatch, scope $"Expected {expected}, found {node.mKind}", 0, 0, 0, 0);
	}

	/// The error with `/name` prepended to its path.
	public static ToyError AtMember(ToyError error, StringView name)
	{
		var error;
		error.PrependPath(scope $"/{name}");
		return error;
	}

	/// The error with `/index` prepended to its path.
	public static ToyError AtIndex(ToyError error, int index)
	{
		var error;
		error.PrependPath(scope $"/{index}");
		return error;
	}

	public static ToyError Missing(StringView name)
	{
		return ToyError(.MissingValue, scope $"The required member \"{name}\" is missing", 0, 0, 0, 0);
	}

	public static ToyError UnknownCase(StringView text, StringView cases)
	{
		return ToyError(.InvalidValue, scope $"\"{text}\" is not one of: {cases}", 0, 0, 0, 0);
	}

	public static ToyError Invalid(StringView message)
	{
		return ToyError(.InvalidValue, message, 0, 0, 0, 0);
	}

	public static Result<bool, ToyError> ReadBool(ToyNode node)
	{
		if (node.mKind != .Bool)
			return .Err(Mismatch(node, "a bool"));
		return node.mBool;
	}

	public static Result<int64, ToyError> ReadInteger(ToyNode node, int64 min, int64 max)
	{
		int64 value;
		if (node.mKind == .Integer)
			value = node.mInteger;
		else if (node.mKind == .UInteger)
			return .Err(ToyError(.OutOfRange, scope $"{node.mUInteger} is outside the range {min} to {max}", 0, 0, 0, 0));
		else
			return .Err(Mismatch(node, "an integer"));
		if (value < min || value > max)
			return .Err(ToyError(.OutOfRange, scope $"{value} is outside the range {min} to {max}", 0, 0, 0, 0));
		return value;
	}

	public static Result<uint64, ToyError> ReadUInt64(ToyNode node)
	{
		if (node.mKind == .UInteger)
			return node.mUInteger;
		if (node.mKind == .Integer)
		{
			if (node.mInteger < 0)
				return .Err(ToyError(.OutOfRange, scope $"{node.mInteger} is outside the range 0 to 18446744073709551615", 0, 0, 0, 0));
			return (uint64)node.mInteger;
		}
		return .Err(Mismatch(node, "an integer"));
	}

	public static Result<double, ToyError> ReadDouble(ToyNode node)
	{
		switch (node.mKind)
		{
		case .Float: return node.mFloat;
		case .Integer: return (double)node.mInteger;
		case .UInteger: return (double)node.mUInteger;
		default: return .Err(Mismatch(node, "a number"));
		}
	}

	public static Result<StringView, ToyError> ReadText(ToyNode node)
	{
		if (node.mKind != .Text)
			return .Err(Mismatch(node, "text"));
		return StringView(node.mText);
	}

	/// Sets `target` (null: a new String from `alloc`, or the heap) to the node's text, or to null.
	public static Result<void, ToyError> ReadString(ToyNode node, ref String target, ITypedAllocator alloc)
	{
		if (node.mKind == .Null)
		{
			if (alloc == null)
				delete target;
			target = null;
			return .Ok;
		}
		if (node.mKind != .Text)
			return .Err(Mismatch(node, "text"));
		if (target == null)
			target = (alloc != null) ? new:alloc String(node.mText) : new String(node.mText);
		else
			target.Set(node.mText);
		return .Ok;
	}

	public static Result<void, ToyError> Expect(ToyNode node, ToyKind kind, StringView what)
	{
		if (node.mKind != kind)
			return .Err(Mismatch(node, what));
		return .Ok;
	}

	public static Result<int64, ToyError> ParseKeyInteger(StringView text, int64 min, int64 max)
	{
		switch (int64.Parse(text))
		{
		case .Ok(let value):
			if (value < min || value > max)
				return .Err(ToyError(.OutOfRange, scope $"The key {value} is outside the range {min} to {max}", 0, 0, 0, 0));
			return value;
		case .Err:
			return .Err(ToyError(.InvalidValue, scope $"The key \"{text}\" is not an integer", 0, 0, 0, 0));
		}
	}

	public static Result<uint64, ToyError> ParseKeyUInt64(StringView text)
	{
		switch (uint64.Parse(text))
		{
		case .Ok(let value):
			return value;
		case .Err:
			return .Err(ToyError(.InvalidValue, scope $"The key \"{text}\" is not an unsigned integer", 0, 0, 0, 0));
		}
	}

	public static void WriteString(ToyNode node, String value)
	{
		if (value == null)
			node.Reset();
		else
			node.SetText(value);
	}
}
