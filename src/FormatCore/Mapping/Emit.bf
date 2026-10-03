using System;
using System.Collections;
using System.Reflection;
using internal FormatCore;

namespace FormatCore.Mapping;

/// Beef source text for emitted code: string literals and integer bounds. Ordinary methods (callable at
/// compile time and in tests).
internal static class Literal
{
	/// @brief Append `text` as a Beef string literal. Quotes and backslashes are escaped, and so is every
	/// control character (`\n`, `\t`, `\r`, else `\u{X}`), so the literal is valid whatever the text (the
	/// generated source shown by a ShowGenerated property holds newlines).
	/// @param code The source to append to.
	/// @param text The text.
	public static void Append(String code, StringView text)
	{
		code.Append('"');
		for (let c in text.RawChars)
		{
			switch (c)
			{
			case '"': code.Append("\\\"");
			case '\\': code.Append("\\\\");
			case '\n': code.Append("\\n");
			case '\t': code.Append("\\t");
			case '\r': code.Append("\\r");
			default:
				if ((uint8)c < 0x20 || c == (char8)0x7F)
					code.AppendF("\\u{{{0:X}}}", (uint8)c);
				else
					code.Append(c);
			}
		}
		code.Append('"');
	}
}

/// Integer bounds of field types, as source text.
internal static class IntegerBounds
{
	/// @brief The smallest and largest value of an integer type as int64 source expressions, for a
	/// reader that checks a value it read as an int64. A 64-bit unsigned type's minimum is 0 (the
	/// siblings' copies gave every 64-bit type int64.MinValue: a negative number would have reached a
	/// uint64 field had a caller not routed uint64 elsewhere); its maximum is int64.MaxValue, the largest
	/// an int64 holds: read uint64 through its own path (TypeShapes.IsUInt64) for the full range.
	/// @param type An integer type.
	/// @param min Receives the minimum.
	/// @param max Receives the maximum.
	public static void Range(Type type, String min, String max)
	{
		int bits = type.Size * 8;
		if (type.IsSigned)
		{
			if (bits == 64)
			{
				min.Append("int64.MinValue");
				max.Append("int64.MaxValue");
			}
			else
			{
				min.AppendF("{}", -(1L << (bits - 1)));
				max.AppendF("{}", (1L << (bits - 1)) - 1);
			}
			return;
		}
		min.Append("0");
		if (bits == 64)
			max.Append("int64.MaxValue");
		else
			max.AppendF("{}", (1L << bits) - 1);
	}

	/// @brief The exact range of an integer type in decimal, for messages ("0 to 18446744073709551615").
	/// @param type An integer type.
	/// @param min Receives the minimum.
	/// @param max Receives the maximum.
	public static void RangeText(Type type, String min, String max)
	{
		int bits = type.Size * 8;
		if (type.IsSigned)
		{
			if (bits == 64)
			{
				min.Append("-9223372036854775808");
				max.Append("9223372036854775807");
			}
			else
			{
				min.AppendF("{}", -(1L << (bits - 1)));
				max.AppendF("{}", (1L << (bits - 1)) - 1);
			}
			return;
		}
		min.Append("0");
		if (bits == 64)
			max.Append("18446744073709551615");
		else
			max.AppendF("{}", (1L << bits) - 1);
	}
}

/// A component of the error path generated code prepends to an error leaving a nested value: a member
/// name (a literal or a String expression) or an index (an int expression).
internal class PathPart
{
	public bool mIsIndex;
	public String mExpr = new .() ~ delete _;

	public this(bool isIndex, StringView expr)
	{
		mIsIndex = isIndex;
		mExpr.Set(expr);
	}
}

/// Code being written (JsonBeef's Emitter): the buffer, unique local names, the error path of the value
/// being emitted, and the format's templates for wrapping an error in that path.
internal class CodeWriter
{
	public String mCode = new .() ~ delete _;
	public int mNext;
	/// The planned type's full name and the field being emitted, for messages.
	public String mOwner = new .() ~ delete _;
	public String mField = new .() ~ delete _;
	public List<PathPart> mPath = new .() ~ DeleteContainerAndItems!(_);
	/// The naming of the field being emitted: its enum cases follow it.
	public NamingPolicy mNaming;
	/// The expression that adds a member name to an error: `{0}` the error, `{1}` the name expression.
	public String mWrapMember = new .("{0}") ~ delete _;
	/// The expression that adds an index to an error: `{0}` the error, `{1}` the index expression.
	public String mWrapIndex = new .("{0}") ~ delete _;

	public this()
	{
	}

	/// @brief A fresh local name: `_<prefix><n>`.
	/// @param prefix The name's prefix.
	/// @param name The string to append to.
	/// @return `name`.
	public String Local(StringView prefix, String name)
	{
		name.AppendF("_{}{}", prefix, mNext++);
		return name;
	}

	/// @brief Push a member name (an expression) onto the error path.
	public void PushMember(StringView nameExpr)
	{
		mPath.Add(new .(false, nameExpr));
	}

	/// @brief Push an index (an expression) onto the error path.
	public void PushIndex(StringView indexExpr)
	{
		mPath.Add(new .(true, indexExpr));
	}

	/// @brief Pop the error path's innermost part.
	public void Pop()
	{
		delete mPath.PopBack();
	}

	/// @brief `error` (an expression) wrapped in the current path, innermost part first.
	/// @param error The error expression.
	/// @param result The string to append to.
	public void Wrap(StringView error, String result)
	{
		let expr = scope String(error);
		for (int i = mPath.Count - 1; i >= 0; i--)
		{
			let part = mPath[i];
			let wrapped = scope String(part.mIsIndex ? mWrapIndex : mWrapMember);
			wrapped.Replace("{1}", part.mExpr);
			wrapped.Replace("{0}", expr);
			expr.Set(wrapped);
		}
		result.Append(expr);
	}

	/// @brief `return .Err(<error wrapped in the path>);` at `indent`.
	public void Return(StringView indent, StringView error)
	{
		mCode.AppendF("{}return .Err(", indent);
		Wrap(error, mCode);
		mCode.Append(");\n");
	}

	/// @brief `assign` (a statement with `{0}`) with `value` for `{0}`, on its own line.
	public void Assign(StringView indent, StringView assign, StringView value)
	{
		mCode.Append(indent);
		mCode.Append(scope String(assign)..Replace("{0}", value));
		mCode.Append('\n');
	}
}

/// Generated enum code with one case-naming rule for every format: a field's enum cases take the naming
/// of the level that declares the field (JsonBeef's rule; TOML wrote them as declared, KDL and XML used
/// the enum's own naming).
internal static class EnumEmit
{
	/// @brief The enum's simple cases (fields that are enum cases).
	public static void Cases(Type enumType, List<FieldInfo> cases)
	{
		for (let field in enumType.GetFields())
		{
			if (field.IsEnumCase)
				cases.Add(field);
		}
	}

	/// @brief The cases' names under `naming`, separated by ", " (for messages).
	public static void CaseList(Type enumType, NamingPolicy naming, String list)
	{
		for (let field in enumType.GetFields())
		{
			if (!field.IsEnumCase)
				continue;
			if (!list.IsEmpty)
				list.Append(", ");
			Naming.Apply(field.Name, naming, list);
		}
	}

	/// @brief `switch (text) { case "name": target = .Case; ... default: <fail> }`.
	/// @param code The source to append to.
	/// @param indent The indentation.
	/// @param enumType The enum.
	/// @param naming The case naming.
	/// @param textExpr The text being parsed (a StringView expression).
	/// @param target The local or field to set.
	/// @param fail The default case's statement (a `return .Err(...)`), with its own indentation.
	public static void EmitParse(String code, StringView indent, Type enumType, NamingPolicy naming, StringView textExpr, StringView target, StringView fail)
	{
		code.AppendF("{}switch ({})\n{}{{\n", indent, textExpr, indent);
		for (let field in enumType.GetFields())
		{
			if (!field.IsEnumCase)
				continue;
			code.AppendF("{}case ", indent);
			Literal.Append(code, Naming.Apply(field.Name, naming, .. scope .()));
			code.AppendF(": {} = .{};\n", target, field.Name);
		}
		code.AppendF("{}default:\n{}{}}}\n", indent, fail, indent);
	}

	/// @brief `switch (value) { case .Case: <statement with the name literal for {0}> ... default: <fail> }`.
	/// @param code The source to append to.
	/// @param indent The indentation.
	/// @param enumType The enum.
	/// @param naming The case naming.
	/// @param valueExpr The enum value.
	/// @param statement A statement with `{0}` for the case's name literal.
	/// @param fail The default case's statement (an enum value that is no case), with its own indentation.
	public static void EmitFormat(String code, StringView indent, Type enumType, NamingPolicy naming, StringView valueExpr, StringView statement, StringView fail)
	{
		code.AppendF("{}switch ({})\n{}{{\n", indent, valueExpr, indent);
		for (let field in enumType.GetFields())
		{
			if (!field.IsEnumCase)
				continue;
			let literal = scope String();
			Literal.Append(literal, Naming.Apply(field.Name, naming, .. scope .()));
			code.AppendF("{}case .{}: {}\n", indent, field.Name, scope String(statement)..Replace("{0}", literal));
		}
		code.AppendF("{}default:\n{}{}}}\n", indent, fail, indent);
	}

	/// @brief `value == .A || value == .B ...`: whether an enum value is one of its cases.
	public static void EmitIsCase(String code, Type enumType, StringView value)
	{
		int count = 0;
		for (let field in enumType.GetFields())
		{
			if (!field.IsEnumCase)
				continue;
			if (count++ > 0)
				code.Append(" || ");
			code.AppendF("{} == .{}", value, field.Name);
		}
		if (count == 0)
			code.Append("false");
	}
}

/// Generated code that owns values: what a read replaces or a container's items hold is deleted when
/// the read has no allocator (`_alloc == null` in the generated method: then the object owns what it
/// creates). JsonBeef's recursive version.
internal static class Ownership
{
	/// @brief `new T(args)` from the read's allocator `_alloc` when there is one, else the heap.
	public static void NewExpr(String code, StringView typeName, StringView args = "")
	{
		code.AppendF("((_alloc != null) ? new:_alloc {0}({1}) : new {0}({1}))", typeName, args);
	}

	/// @brief Delete `expr` (when owned: no allocator, not null) and what it owns.
	public static void EmitDeleteOwned(String code, StringView indent, ValueSpec spec, StringView expr)
	{
		if (!spec.NeedsDelete)
			return;
		code.AppendF("{}if (_alloc == null && {} != null)\n{}{{\n", indent, expr, indent);
		EmitDelete(code, scope $"{indent}\t", spec, expr);
		code.AppendF("{}}}\n", indent);
	}

	/// @brief Delete `expr` and everything it owns (a List's or Dictionary's items, keys, nested
	/// containers).
	public static void EmitDelete(String code, StringView indent, ValueSpec spec, StringView expr)
	{
		if (!spec.NeedsDelete)
			return;
		if (spec.mKind == .List || spec.mKind == .Dictionary)
			EmitClearItems(code, indent, spec, expr);
		code.AppendF("{}delete {};\n", indent, expr);
	}

	/// @brief Delete what a List's or Dictionary's items own (not the container itself).
	public static void EmitClearItems(String code, StringView indent, ValueSpec spec, StringView expr)
	{
		bool ownsKeys = spec.mKind == .Dictionary && spec.mKeyKind == .String;
		bool ownsItems = spec.mItem.NeedsDelete;
		if (!ownsKeys && !ownsItems)
			return;
		let item = scope $"_x{indent.Length}";
		code.AppendF("{}if (_alloc == null)\n{}{{\n{}\tfor (let {} in {})\n{}\t{{\n", indent, indent, indent, item, expr, indent);
		if (spec.mKind == .Dictionary)
		{
			if (ownsKeys)
				code.AppendF("{}\t\tdelete {}.key;\n", indent, item);
			if (ownsItems)
			{
				code.AppendF("{}\t\tif ({}.value != null)\n{}\t\t{{\n", indent, item, indent);
				EmitDelete(code, scope $"{indent}\t\t\t", spec.mItem, scope $"{item}.value");
				code.AppendF("{}\t\t}}\n", indent);
			}
		}
		else
		{
			code.AppendF("{}\t\tif ({} != null)\n{}\t\t{{\n", indent, item, indent);
			EmitDelete(code, scope $"{indent}\t\t\t", spec.mItem, item);
			code.AppendF("{}\t\t}}\n", indent);
		}
		code.AppendF("{}\t}}\n{}}}\n", indent, indent);
	}
}

/// The deferred-body driver every format uses (JsonBeef's model, with the registry fix):
///
/// - In `ApplyToType` the format emits only signatures (and the interface), plus, through EmitEntry, a
///   `[Comptime]` method in the user's type that calls the format's generator for `typeof(Self)`.
/// - Each generated method's body is `System.Compiler.Mixin(<entry>(part))` (AppendBody): it is planned
///   and written when the method is compiled, when every type is complete (a type can hold itself,
///   `List<Node> children`, without the type-initialization cycle that crashed the compiler).
/// - The evaluation's entry point is the user's own method, so "current" for `Type.TypeDeclarations`
///   is the user's project: converter and subtype lookups (Registry) see exactly the user's project and
///   its dependencies, however many projects depend on the format library.
///
/// Never emit an `[OnCompile]` method from ApplyToType: BeefBuild 0.43.6 crashes (exit 139).
internal static class MappingDriver
{
	/// @brief Emit the user-side entry `[Comptime] static String <entry>(int _part, String _args =
	/// null) => <generator>(typeof(Self), _part, _args);` into `type`.
	/// @param type The mapped type.
	/// @param entry The entry's name (distinctive per format: `TomlGen_`), hidden with `new` when a base
	/// level has one.
	/// @param generator The format's public `[Comptime] static String Body(Type, int, String)`, fully
	/// qualified (`TomlBeef.TomlSerializerCodeGen.Body`).
	/// @param hidesBase Whether a base level of the chain has the entry too.
	[Comptime]
	public static void EmitEntry(Type type, StringView entry, StringView generator, bool hidesBase)
	{
		Compiler.EmitTypeBody(type, scope $"[System.Comptime]\n{hidesBase ? "new " : ""}static System.String {entry}(int _part, System.String _args = null) => {generator}(typeof(Self), _part, _args);\n");
	}

	/// @brief Append the statement that is a generated method's body: `System.Compiler.Mixin(<entry>(part, args))`.
	/// @param code The source to append to.
	/// @param indent The indentation.
	/// @param entry The entry's name.
	/// @param part The part the generator writes.
	/// @param args Text handed to the generator (as a literal), or empty.
	public static void AppendBody(String code, StringView indent, StringView entry, int part, StringView args = "")
	{
		code.AppendF("{}System.Compiler.Mixin({}({}", indent, entry, part);
		if (!args.IsEmpty)
		{
			code.Append(", ");
			Literal.Append(code, args);
		}
		code.Append("));\n");
	}

	/// @brief Whether `type` is the unspecialized form of a generic type (`Box<T>`, or a specialization
	/// over another type's generic parameters). Its methods are compiled but a comptime method of it
	/// cannot be evaluated: emit stub bodies (`return .Ok;`) instead of AppendBody, and no entry. Each
	/// specialization gets ApplyToType of its own, with real bodies.
	[Comptime]
	public static bool IsOpenType(Type type)
	{
		if (TypeShapes.IsOpen(type))
			return true;
		return type.IsGenericType && !(type is SpecializedGenericType);
	}

	/// @brief Whether `type`'s base class is a mapped level too (its methods are then overridden, and
	/// its entry hidden).
	[Comptime]
	public static bool BaseIsLevel<TFormat>(Type type) where TFormat : IMappingFormat
	{
		return !type.IsValueType && type.BaseType != null && type.BaseType != typeof(Object) && TFormat.IsObjectLevel(type.BaseType);
	}

	/// @brief The modifiers of a generated instance method: whole-chain methods (JsonBeef's model) are
	/// `virtual` on a class's base-most level and `override` below it; a struct's are `mut` readers.
	/// @param type The mapped type.
	/// @param baseIsLevel Whether its base is a mapped level.
	/// @param modifier Receives "", "virtual " or "override ".
	/// @param mutating Receives " mut" for a struct, else "".
	public static void Modifiers(Type type, bool baseIsLevel, String modifier, String mutating)
	{
		modifier.Append(type.IsValueType ? "" : baseIsLevel ? "override " : "virtual ");
		mutating.Append(type.IsValueType ? " mut" : "");
	}
}
