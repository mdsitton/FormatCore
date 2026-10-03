using System;
using System.Collections;
using System.Reflection;
using FormatCore.Mapping;
using internal FormatCore;

namespace ToyFormat;

/// The toy format's part in planning: [ToyObject] levels, Toy* field attributes, one place for names.
public struct ToyMapping : IMappingFormat
{
	public static StringView Prefix => "[ToyObject]";
	public static StringView ConverterAttributeName => "[ToyConverter]";
	public static StringView UseConverterAttributeName => "[ToyUseConverter]";
	public static StringView SupportedTypes => "bool, integers, float, double, String, enums, [ToyObject] types, T? of value types, Lists and Dictionaries (String, integer or enum keys) of any of these";

	[Comptime]
	public static bool IsObjectLevel(Type type) => type.HasCustomAttribute<ToyObjectAttribute>();

	[Comptime]
	public static bool IsObject(Type type) => IsObjectLevel(type) || (!type.IsInterface && type.ImplementsInterface(typeof(IToySerializable)));

	[Comptime]
	public static bool IsPolymorphic(Type type) => false;

	[Comptime]
	public static void ReadLevel(Type level, ref LevelOptions options)
	{
		if (level.GetCustomAttribute<ToyObjectAttribute>() case .Ok(let attribute))
			options.mNaming = attribute.Naming;
	}

	[Comptime]
	public static bool IsIgnored(FieldInfo field) => field.HasCustomAttribute<ToyIgnoreAttribute>();

	[Comptime]
	public static void ReadField(FieldInfo field, MemberPlan member)
	{
		if (field.GetCustomAttribute<ToyNameAttribute>() case .Ok(let named))
			member.mName.Set(named.mName);
		for (let alias in field.GetCustomAttributes<ToyAliasAttribute>())
			member.mAliases.Add(new .(alias.mName));
		member.mRequired = field.HasCustomAttribute<ToyRequiredAttribute>();
		if (field.GetCustomAttribute<ToyUseConverterAttribute>() case .Ok(let use))
			member.mUseConverter = use.mConverter;
	}

	[Comptime]
	public static int FormatScalar(Type type) => -1;

	[Comptime]
	public static Type ConverterTarget(TypeDeclaration declaration)
	{
		if (declaration.GetCustomAttribute<ToyConverterAttribute>() case .Ok(let registration))
			return registration.mTarget;
		return null;
	}

	[Comptime]
	public static void AssignRole(MemberPlan member, TypePlan plan, ClaimSet claims)
	{
		let path = member.AppendPath(.. scope .());
		claims.mHint.Set("names come from [ToyName], [ToyAlias] or the field's name through the Naming");
		claims.Add<ToyMapping>(0, member.mName, path);
		for (let alias in member.mAliases)
			claims.Add<ToyMapping>(0, alias, path);
	}

	[Comptime]
	public static bool Allows(MemberPlan member, ValueSpec spec, String why)
	{
		if (spec.mKind == .Nullable && !spec.mItem.mType.IsValueType)
		{
			why.Append("Nullable needs a value type");
			return false;
		}
		if (spec.mItem != null)
			return Allows(member, spec.mItem, why);
		return true;
	}

	public static bool Overlaps(int placeA, StringView nameA, int placeB, StringView nameB) => placeA == placeB && nameA == nameB;
}

/// The compile-time half of [ToyObject]: signatures in ApplyToType, bodies in the mixin stage
/// (FormatCore.Mapping.MappingDriver).
public static class ToyCodeGen
{
	const String cEntry = "ToyGen_";

	[Comptime]
	public static void Emit(Type type, ToyObjectAttribute attribute)
	{
		bool baseIsLevel = MappingDriver.BaseIsLevel<ToyMapping>(type);
		let modifier = scope String();
		let mutating = scope String();
		MappingDriver.Modifiers(type, baseIsLevel, modifier, mutating);
		if (!baseIsLevel)
			Compiler.EmitAddInterface(type, typeof(IToySerializable));
		// The unspecialized pass of a generic type: stubs (its specializations get real bodies)
		bool open = MappingDriver.IsOpenType(type);
		if (!open)
			MappingDriver.EmitEntry(type, cEntry, "ToyFormat.ToyCodeGen.Body", baseIsLevel);
		let code = scope String();
		code.AppendF("public {}Result<void, ToyFormat.ToyError> ToyRead(ToyFormat.ToyNode _node, System.ITypedAllocator _alloc = null){}\n{{\n", modifier, mutating);
		if (open)
			code.Append("\treturn .Ok;\n");
		else
			MappingDriver.AppendBody(code, "\t", cEntry, 0);
		code.AppendF("}}\npublic {}void ToyWrite(ToyFormat.ToyNode _node)\n{{\n", modifier);
		if (!open)
			MappingDriver.AppendBody(code, "\t", cEntry, 1);
		code.Append("}\n");
		if (attribute.ShowRegistry && !open)
		{
			code.Append("public static System.StringView ToyRegistryNow\n{\n\tget\n\t{\n");
			MappingDriver.AppendBody(code, "\t\t", cEntry, 2);
			code.Append("\t}\n}\n");
			code.Append("public static System.StringView ToyRegistryAtApply => ");
			Literal.Append(code, OldLookup(type, .. scope .()));
			code.Append(";\n");
		}
		Compiler.EmitTypeBody(type, code);
	}

	/// What the siblings' generators find inside ApplyToType (`DeclaredInCurrent || DeclaredInDependency
	/// || AlwaysVisible`, current being the format library): kept only to show the difference.
	[Comptime]
	static void OldLookup(Type type, String text)
	{
		for (let field in type.GetFields())
		{
			if (field.DeclaringType != type || field.IsStatic || !field.IsPublic)
				continue;
			Type found = null;
			for (let declaration in Type.TypeDeclarations)
			{
				if (!(declaration.DeclaredInCurrent || declaration.DeclaredInDependency || declaration.AlwaysVisible))
					continue;
				if (ToyMapping.ConverterTarget(declaration) == field.FieldType)
					found = declaration.ResolvedType;
			}
			text.AppendF("{}={} ", field.Name, (found != null) ? found.GetName(.. scope .()) : "none");
		}
	}

	/// @brief The body of one generated member of `type`, mixed in when it is compiled (through the
	/// [Comptime] entry MappingDriver emitted into the type, so lookups see the user's project).
	/// @param type The [ToyObject] type.
	/// @param part 0: ToyRead, 1: ToyWrite, 2: ToyRegistryNow.
	/// @param args Unused.
	/// @return The code.
	[Comptime]
	public static String Body(Type type, int part, String args)
	{
		let plan = Planner<ToyMapping>.Plan(type);
		defer delete plan;
		let e = scope CodeWriter();
		e.mOwner.Set(plan.mOwnerName);
		e.mWrapMember.Set("ToyFormat.ToyBind.AtMember({0}, {1})");
		e.mWrapIndex.Set("ToyFormat.ToyBind.AtIndex({0}, {1})");
		if (plan.mOpen)
		{
			// The unspecialized pass of a generic type: compiles, never runs
			if (part == 0)
				e.mCode.Append("return .Ok;\n");
			else if (part == 2)
				e.mCode.Append("return \"\";\n");
			return new String(e.mCode);
		}
		switch (part)
		{
		case 0: EmitRead(e, plan);
		case 1: EmitWrite(e, plan);
		default: EmitRegistry(e, plan);
		}
		return new String(e.mCode);
	}

	[Comptime]
	static void EmitRegistry(CodeWriter e, TypePlan plan)
	{
		let text = scope String();
		for (let member in plan.mMembers)
		{
			Type converter = member.mSpec.mConverter;
			text.AppendF("{}={} ", member.mField.Name, (member.mSpec.mKind == .Converter) ? converter.GetName(.. scope .()) : "none");
		}
		e.mCode.Append("return ");
		Literal.Append(e.mCode, text);
		e.mCode.Append(";\n");
	}

	// Reading

	[Comptime]
	static void EmitRead(CodeWriter e, TypePlan plan)
	{
		let code = e.mCode;
		code.Append("\tif (ToyFormat.ToyBind.Expect(_node, .Map, \"a map\") case .Err(let _me))\n\t\treturn .Err(_me);\n");
		for (let member in plan.mMembers)
		{
			let node = e.Local("v", .. scope .());
			let name = Literal.Append(.. scope .(), member.mName);
			code.AppendF("\t{{\n\t\tToyFormat.ToyNode {} = _node.Get({});\n", node, name);
			for (let alias in member.mAliases)
				code.AppendF("\t\tif ({0} == null)\n\t\t\t{0} = _node.Get({1});\n", node, Literal.Append(.. scope .(), alias));
			code.AppendF("\t\tif ({} == null)\n\t\t{{\n", node);
			if (member.mRequired)
				code.AppendF("\t\t\treturn .Err(ToyFormat.ToyBind.Missing({}));\n", name);
			code.Append("\t\t}\n\t\telse\n\t\t{\n");
			e.mField.Set(member.mField.Name);
			e.mNaming = member.mNaming;
			e.PushMember(name);
			let target = scope $"this.{member.mField.Name}";
			EmitReadValue(e, "\t\t\t", member.mSpec, node, target, scope $"{target} = {{0}};");
			e.Pop();
			code.Append("\t\t}\n\t}\n");
		}
		code.Append("\treturn .Ok;\n");
	}

	/// `Result` of a ToyBind read into `local`, or a return of its error wrapped in the path.
	[Comptime]
	static void EmitResult(CodeWriter e, StringView indent, StringView call, StringView type, StringView local)
	{
		let error = e.Local("er", .. scope .());
		e.mCode.AppendF("{0}{1} {2} = default;\n{0}switch ({3})\n{0}{{\n{0}case .Ok(let _ok): {2} = _ok;\n{0}case .Err(let {4}):\n", indent, type, local, call, error);
		e.Return(scope $"{indent}\t", error);
		e.mCode.AppendF("{}}}\n", indent);
	}

	/// Reads the value of node `node` into `existing` (a field, kept and filled where it can be), or
	/// when `existing` is empty into a new value handed to `assign` (a statement with `{0}`).
	[Comptime]
	static void EmitReadValue(CodeWriter e, StringView indent, ValueSpec spec, StringView node, StringView existing, StringView assign)
	{
		let code = e.mCode;
		let typeName = spec.mType.GetFullName(.. scope .());
		let inner = scope $"{indent}\t";
		code.AppendF("{}{{\n", indent);
		switch (spec.mKind)
		{
		case .Bool:
			let local = e.Local("b", .. scope .());
			EmitResult(e, inner, scope $"ToyFormat.ToyBind.ReadBool({node})", "bool", local);
			e.Assign(inner, assign, local);
		case .Integer:
			let local = e.Local("i", .. scope .());
			if (TypeShapes.IsUInt64(spec.mType))
				EmitResult(e, inner, scope $"ToyFormat.ToyBind.ReadUInt64({node})", "uint64", local);
			else
			{
				let min = scope String();
				let max = scope String();
				IntegerBounds.Range(spec.mType, min, max);
				EmitResult(e, inner, scope $"ToyFormat.ToyBind.ReadInteger({node}, {min}, {max})", "int64", local);
			}
			e.Assign(inner, assign, scope $"({typeName}){local}");
		case .Float:
			let local = e.Local("d", .. scope .());
			EmitResult(e, inner, scope $"ToyFormat.ToyBind.ReadDouble({node})", "double", local);
			e.Assign(inner, assign, scope $"({typeName}){local}");
		case .String:
			let error = e.Local("er", .. scope .());
			if (!existing.IsEmpty)
			{
				code.AppendF("{}if (ToyFormat.ToyBind.ReadString({}, ref {}, _alloc) case .Err(let {}))\n", inner, node, existing, error);
				e.Return(scope $"{inner}\t", error);
			}
			else
			{
				let local = e.Local("s", .. scope .());
				code.AppendF("{0}System.String {1} = null;\n{0}if (ToyFormat.ToyBind.ReadString({2}, ref {1}, _alloc) case .Err(let {3}))\n", inner, local, node, error);
				e.Return(scope $"{inner}\t", error);
				e.Assign(inner, assign, local);
			}
		case .Enum:
			let text = e.Local("t", .. scope .());
			let local = e.Local("e", .. scope .());
			EmitResult(e, inner, scope $"ToyFormat.ToyBind.ReadText({node})", "System.StringView", text);
			code.AppendF("{}{} {} = default;\n", inner, typeName, local);
			let cases = EnumEmit.CaseList(spec.mType, e.mNaming, .. scope .());
			let wrapped = scope String();
			e.Wrap(scope $"ToyFormat.ToyBind.UnknownCase({text}, {Literal.Append(.. scope .(), cases)})", wrapped);
			EnumEmit.EmitParse(code, inner, spec.mType, e.mNaming, text, local, scope $"{inner}\treturn .Err({wrapped});\n");
			e.Assign(inner, assign, local);
		case .Converter:
			let converterName = spec.mConverter.GetFullName(.. scope .());
			let error = e.Local("er", .. scope .());
			if (!existing.IsEmpty)
			{
				code.AppendF("{}if ({}.Read({}, ref {}) case .Err(let {}))\n", inner, converterName, node, existing, error);
				e.Return(scope $"{inner}\t", error);
			}
			else
			{
				let local = e.Local("c", .. scope .());
				code.AppendF("{0}{1} {2} = default;\n{0}if ({3}.Read({4}, ref {2}) case .Err(let {5}))\n", inner, typeName, local, converterName, node, error);
				e.Return(scope $"{inner}\t", error);
				e.Assign(inner, assign, local);
			}
		case .Nullable:
			code.AppendF("{}if ({}.mKind == .Null)\n", inner, node);
			e.Assign(scope $"{inner}\t", assign, "null");
			code.AppendF("{}else\n", inner);
			EmitReadValue(e, inner, spec.mItem, node, "", assign);
		case .Object:
			EmitReadObject(e, inner, spec, node, existing, assign);
		case .List:
			EmitReadList(e, inner, spec, node, existing, assign);
		case .Dictionary:
			EmitReadDictionary(e, inner, spec, node, existing, assign);
		default:
		}
		code.AppendF("{}}}\n", indent);
	}

	[Comptime]
	static void EmitReadObject(CodeWriter e, StringView indent, ValueSpec spec, StringView node, StringView existing, StringView assign)
	{
		let code = e.mCode;
		let typeName = spec.mType.GetFullName(.. scope .());
		let error = e.Local("er", .. scope .());
		if (spec.mType.IsValueType)
		{
			if (!existing.IsEmpty)
			{
				code.AppendF("{}if ({}.ToyRead({}, _alloc) case .Err(let {}))\n", indent, existing, node, error);
				e.Return(scope $"{indent}\t", error);
			}
			else
			{
				let local = e.Local("o", .. scope .());
				code.AppendF("{0}{1} {2} = default;\n{0}if ({2}.ToyRead({3}, _alloc) case .Err(let {4}))\n", indent, typeName, local, node, error);
				e.Return(scope $"{indent}\t", error);
				e.Assign(indent, assign, local);
			}
			return;
		}
		code.AppendF("{}if ({}.mKind == .Null)\n{}{{\n", indent, node, indent);
		if (!existing.IsEmpty)
			Ownership.EmitDeleteOwned(code, scope $"{indent}\t", spec, existing);
		e.Assign(scope $"{indent}\t", assign, "null");
		code.AppendF("{}}}\n{}else\n{}{{\n", indent, indent, indent);
		let inner = scope $"{indent}\t";
		if (!existing.IsEmpty)
		{
			code.AppendF("{0}if ({1} == null)\n{0}\t{1} = {2};\n{0}if ({1}.ToyRead({3}, _alloc) case .Err(let {4}))\n", inner, existing, Ownership.NewExpr(.. scope .(), typeName), node, error);
			e.Return(scope $"{inner}\t", error);
		}
		else
		{
			// Handed over before it is read, so it is owned even if reading fails
			let local = e.Local("o", .. scope .());
			code.AppendF("{}let {} = {};\n", inner, local, Ownership.NewExpr(.. scope .(), typeName));
			e.Assign(inner, assign, local);
			code.AppendF("{}if ({}.ToyRead({}, _alloc) case .Err(let {}))\n", inner, local, node, error);
			e.Return(scope $"{inner}\t", error);
		}
		code.AppendF("{}}}\n", indent);
	}

	/// The container `existing` emptied (its items deleted) or created, in `local`; or a new one handed
	/// to `assign`. A Null node sets it to null.
	[Comptime]
	static void EmitContainerStart(CodeWriter e, StringView indent, ValueSpec spec, StringView node, StringView existing, StringView assign, ToyKind kind, StringView what, StringView local)
	{
		let code = e.mCode;
		let typeName = spec.mType.GetFullName(.. scope .());
		code.AppendF("{}if ({}.mKind == .Null)\n{}{{\n", indent, node, indent);
		if (!existing.IsEmpty)
			Ownership.EmitDeleteOwned(code, scope $"{indent}\t", spec, existing);
		e.Assign(scope $"{indent}\t", assign, "null");
		code.AppendF("{}}}\n{}else\n{}{{\n", indent, indent, indent);
		let inner = scope $"{indent}\t";
		let error = e.Local("er", .. scope .());
		code.AppendF("{}if (ToyFormat.ToyBind.Expect({}, .{}, \"{}\") case .Err(let {}))\n", inner, node, kind, what, error);
		e.Return(scope $"{inner}\t", error);
		if (!existing.IsEmpty)
		{
			code.AppendF("{0}if ({1} == null)\n{0}\t{1} = {2};\n{0}else\n{0}{{\n", inner, existing, Ownership.NewExpr(.. scope .(), typeName));
			Ownership.EmitClearItems(code, scope $"{inner}\t", spec, existing);
			code.AppendF("{0}\t{1}.Clear();\n{0}}}\n{0}let {2} = {1};\n", inner, existing, local);
		}
		else
		{
			code.AppendF("{}let {} = {};\n", inner, local, Ownership.NewExpr(.. scope .(), typeName));
			e.Assign(inner, assign, local);
		}
	}

	[Comptime]
	static void EmitReadList(CodeWriter e, StringView indent, ValueSpec spec, StringView node, StringView existing, StringView assign)
	{
		let code = e.mCode;
		let list = e.Local("l", .. scope .());
		EmitContainerStart(e, indent, spec, node, existing, assign, .List, "a list", list);
		let inner = scope $"{indent}\t";
		let index = e.Local("n", .. scope .());
		let item = e.Local("in", .. scope .());
		code.AppendF("{0}for (int {1} < {2}.mItems.Count)\n{0}{{\n{0}\tlet {3} = {2}.mItems[{1}];\n", inner, index, node, item);
		e.PushIndex(index);
		EmitReadValue(e, scope $"{inner}\t", spec.mItem, item, "", scope $"{list}.Add({{0}});");
		e.Pop();
		code.AppendF("{}}}\n{}}}\n", inner, indent);
	}

	[Comptime]
	static void EmitReadDictionary(CodeWriter e, StringView indent, ValueSpec spec, StringView node, StringView existing, StringView assign)
	{
		let code = e.mCode;
		let map = e.Local("m", .. scope .());
		EmitContainerStart(e, indent, spec, node, existing, assign, .Map, "a map", map);
		let inner = scope $"{indent}\t";
		let body = scope $"{inner}\t";
		let index = e.Local("n", .. scope .());
		let keyText = e.Local("kt", .. scope .());
		let item = e.Local("in", .. scope .());
		let valuePtr = e.Local("vp", .. scope .());
		let valueName = spec.mItem.mType.GetFullName(.. scope .());
		let keyName = spec.mKeyType.GetFullName(.. scope .());
		code.AppendF("{0}for (int {1} < {2}.mItems.Count)\n{0}{{\n{3}System.StringView {4} = {2}.mKeys[{1}];\n{3}let {5} = {2}.mItems[{1}];\n{3}{6}* {7} = null;\n",
			inner, index, node, body, keyText, item, valueName, valuePtr);
		let added = e.Local("ap", .. scope .());
		e.PushMember(keyText);
		if (spec.mKeyKind == .String)
		{
			let addedKey = e.Local("kp", .. scope .());
			code.AppendF("{0}if ({1}.TryAddAlt({2}, let {3}, let {4}))\n{0}{{\n{0}\t*{3} = {5};\n{0}\t{6} = {4};\n{0}}}\n{0}else\n{0}{{\n{0}\t{6} = {4};\n",
				body, map, keyText, addedKey, added, Ownership.NewExpr(.. scope .(), "System.String", keyText), valuePtr);
		}
		else
		{
			let key = e.Local("k", .. scope .());
			if (spec.mKeyKind == .Integer)
			{
				let number = e.Local("i", .. scope .());
				if (TypeShapes.IsUInt64(spec.mKeyType))
					EmitResult(e, body, scope $"ToyFormat.ToyBind.ParseKeyUInt64({keyText})", "uint64", number);
				else
				{
					let min = scope String();
					let max = scope String();
					IntegerBounds.Range(spec.mKeyType, min, max);
					EmitResult(e, body, scope $"ToyFormat.ToyBind.ParseKeyInteger({keyText}, {min}, {max})", "int64", number);
				}
				code.AppendF("{}{} {} = ({}){};\n", body, keyName, key, keyName, number);
			}
			else
			{
				code.AppendF("{}{} {} = default;\n", body, keyName, key);
				let cases = EnumEmit.CaseList(spec.mKeyType, e.mNaming, .. scope .());
				let fail = scope String();
				let wrapped = scope String();
				e.Wrap(scope $"ToyFormat.ToyBind.UnknownCase({keyText}, {Literal.Append(.. scope .(), cases)})", wrapped);
				fail.AppendF("{}\treturn .Err({});\n", body, wrapped);
				EnumEmit.EmitParse(code, body, spec.mKeyType, e.mNaming, keyText, key, fail);
			}
			code.AppendF("{0}if ({1}.TryAdd({2}, ?, let {3}))\n{0}\t{4} = {3};\n{0}else\n{0}{{\n{0}\t{4} = {3};\n", body, map, key, added, valuePtr);
		}
		// A repeated key: read over the earlier value
		if (spec.mItem.NeedsDelete)
		{
			code.AppendF("{}\tif (_alloc == null && *{} != null)\n{}\t{{\n", body, valuePtr, body);
			Ownership.EmitDelete(code, scope $"{body}\t\t", spec.mItem, scope $"(*{valuePtr})");
			code.AppendF("{}\t}}\n", body);
		}
		code.AppendF("{0}}}\n{0}*{1} = default;\n", body, valuePtr);
		EmitReadValue(e, body, spec.mItem, item, "", scope $"*{valuePtr} = {{0}};");
		e.Pop();
		code.AppendF("{}}}\n{}}}\n", inner, indent);
	}

	// Writing

	[Comptime]
	static void EmitWrite(CodeWriter e, TypePlan plan)
	{
		let code = e.mCode;
		code.Append("\t_node.MakeMap();\n");
		for (let member in plan.mMembers)
		{
			let name = Literal.Append(.. scope .(), member.mName);
			e.mNaming = member.mNaming;
			for (let alias in member.mAliases)
				code.AppendF("\t_node.Rename({}, {});\n", Literal.Append(.. scope .(), alias), name);
			code.AppendF("\t{{\n\t\tlet _c = _node.Set({});\n", name);
			EmitWriteValue(e, "\t\t", member.mSpec, scope $"this.{member.mField.Name}", "_c");
			code.Append("\t}\n");
		}
	}

	[Comptime]
	static void EmitWriteValue(CodeWriter e, StringView indent, ValueSpec spec, StringView value, StringView node)
	{
		let code = e.mCode;
		let inner = scope $"{indent}\t";
		switch (spec.mKind)
		{
		case .Bool:
			code.AppendF("{}{}.SetBool({});\n", indent, node, value);
		case .Integer:
			if (!spec.mType.IsSigned && spec.mType.Size == 8)
				code.AppendF("{}{}.SetUInteger((uint64){});\n", indent, node, value);
			else
				code.AppendF("{}{}.SetInteger((int64){});\n", indent, node, value);
		case .Float:
			code.AppendF("{}{}.SetFloat((double){});\n", indent, node, value);
		case .String:
			code.AppendF("{}ToyFormat.ToyBind.WriteString({}, {});\n", indent, node, value);
		case .Enum:
			EnumEmit.EmitFormat(code, indent, spec.mType, e.mNaming, value, scope $"{node}.SetText({{0}});", scope $"{inner}{node}.SetInteger((int64){value});\n");
		case .Converter:
			code.AppendF("{}{}.Write({}, {});\n", indent, spec.mConverter.GetFullName(.. scope .()), value, node);
		case .Nullable:
			let local = e.Local("nv", .. scope .());
			code.AppendF("{0}if ({1}.HasValue)\n{0}{{\n{0}\tlet {2} = {1}.Value;\n", indent, value, local);
			EmitWriteValue(e, inner, spec.mItem, local, node);
			code.AppendF("{0}}}\n{0}else\n{0}\t{1}.Reset();\n", indent, node);
		case .Object:
			if (spec.mType.IsValueType)
				code.AppendF("{}{}.ToyWrite({});\n", indent, value, node);
			else
				code.AppendF("{0}if ({1} == null)\n{0}\t{2}.Reset();\n{0}else\n{0}\t{1}.ToyWrite({2});\n", indent, value, node);
		case .List:
			let item = e.Local("e", .. scope .());
			let child = e.Local("c", .. scope .());
			code.AppendF("{0}{1}.Reset();\n{0}if ({2} != null)\n{0}{{\n{0}\t{1}.MakeList();\n{0}\tfor (let {3} in {2})\n{0}\t{{\n{0}\t\tlet {4} = {1}.Add();\n", indent, node, value, item, child);
			EmitWriteValue(e, scope $"{inner}\t", spec.mItem, item, child);
			code.AppendF("{0}\t}}\n{0}}}\n", indent);
		case .Dictionary:
			let entry = e.Local("kv", .. scope .());
			let child = e.Local("c", .. scope .());
			let key = e.Local("key", .. scope .());
			let body = scope $"{inner}\t";
			code.AppendF("{0}{1}.Reset();\n{0}if ({2} != null)\n{0}{{\n{0}\t{1}.MakeMap();\n{0}\tfor (let {3} in {2})\n{0}\t{{\n", indent, node, value, entry);
			switch (spec.mKeyKind)
			{
			case .String:
				code.AppendF("{0}if ({1}.key == null)\n{0}\tcontinue;\n{0}System.StringView {2} = {1}.key;\n", body, entry, key);
			case .Integer:
				code.AppendF("{0}let {1} = scope System.String();\n{0}{2}.key.ToString({1});\n", body, key, entry);
			default:
				code.AppendF("{}System.StringView {} = default;\n", body, key);
				EnumEmit.EmitFormat(code, body, spec.mKeyType, e.mNaming, scope $"{entry}.key", scope $"{key} = {{0}};", scope $"{body}\tcontinue;\n");
			}
			code.AppendF("{}let {} = {}.Set({});\n", body, child, node, key);
			EmitWriteValue(e, body, spec.mItem, scope $"{entry}.value", child);
			code.AppendF("{0}\t}}\n{0}}}\n", indent);
		default:
		}
	}
}
