using System;
using System.Collections;
using System.Reflection;
using internal FormatCore;

namespace FormatCore.Mapping;

/// What a value is to a typed mapping (JsonBeef's Kind, plus the format's own scalars and the
/// unspecialized pass's open types).
internal enum ValueKind
{
	Unsupported,
	Bool,
	Integer,
	Float,
	String,
	/// A simple enum (no payloads): its case names.
	Enum,
	/// A type the format maps as an object (its attribute, or a hand-written interface).
	Object,
	List,
	/// Dictionary<K, V>.
	Dictionary,
	/// Nullable<T>.
	Nullable,
	/// A converter's: from the field's use-converter attribute, or registered for the type.
	Converter,
	/// A type the format handles itself (TOML's date/times): ValueSpec.mFormatTag says which.
	FormatScalar,
	/// A generic parameter, or a type built from one (the unspecialized pass of a generic type): no
	/// code is generated for it.
	Open
}

/// What a value of one type is, and how its parts are (a List's items, a Dictionary's values and keys,
/// a Nullable's value), recursively (JsonBeef's ValueSpec).
internal class ValueSpec
{
	public Type mType;
	public ValueKind mKind;
	/// The converter type (Converter).
	public Type mConverter;
	/// The List item, Dictionary value or Nullable value.
	public ValueSpec mItem ~ delete _;
	public Type mKeyType;
	public ValueKind mKeyKind;
	/// The format's scalar (FormatScalar), from IMappingFormat.FormatScalar.
	public int mFormatTag = -1;
	/// An Object class the format dispatches to subtypes (IMappingFormat.IsPolymorphic).
	public bool mPolymorphic;
	/// An Enum the format writes as its integer value (JsonBeef's EnumsAsNumbers option).
	public bool mEnumNumbers;

	public this()
	{
	}

	/// @brief Whether a value of this spec owns heap objects to delete when it is replaced (a String, a
	/// class, a List, a Dictionary).
	public bool NeedsDelete
	{
		get
		{
			switch (mKind)
			{
			case .String, .List, .Dictionary:
				return true;
			case .Object, .Converter:
				return !mType.IsValueType;
			default:
				return false;
			}
		}
	}

	/// @brief Whether a value of this spec can be null (a class or container, or a Nullable).
	public bool CanBeNull => mKind == .Nullable || (mType != null && !mType.IsValueType && mKind != .Converter);
}

/// The options a level of a mapped chain gives its fields, from the format's attribute on it.
internal struct LevelOptions
{
	public NamingPolicy mNaming;
}

/// One member a field maps: its names, its value, its slot (JsonBeef's FieldPlan, with KDL and XML's
/// roles as a format-defined number).
internal class MemberPlan
{
	public FieldInfo mField;
	/// The type that declares the field (a level of the chain).
	public Type mLevel;
	public String mName = new .() ~ delete _;
	public List<String> mAliases = new .() ~ DeleteContainerAndItems!(_);
	public bool mRequired;
	/// The field's use-converter attribute's converter, or null.
	public Type mUseConverter;
	public ValueSpec mSpec ~ delete _;
	/// The member's index among the chain's members (base-most first): the bit noting it was read.
	public int mSlot;
	/// The naming of the field's level; enum case names follow it (one rule for every format).
	public NamingPolicy mNaming;
	/// The format's role (KDL argument/property/child, XML attribute/element/text...): its enum, cast.
	public int mRole;
	/// A number the format attaches (KDL's argument index).
	public int mIndex = -1;
	/// Text the format attaches (XML's namespace).
	public String mTag = new .() ~ delete _;

	public this()
	{
	}

	/// @brief `Level.field`, for messages.
	/// @param path The string to append to.
	public void AppendPath(String path)
	{
		mLevel.GetFullName(path);
		path.Append('.');
		path.Append(mField.Name);
	}
}

/// The plan of a mapped type: its chain's levels (base-most first) and every member they map.
internal class TypePlan
{
	public Type mType;
	public String mOwnerName = new .() ~ delete _;
	public List<Type> mLevels = new .() ~ delete _;
	public List<MemberPlan> mMembers = new .() ~ DeleteContainerAndItems!(_);
	public int mSlots;
	/// A member's type is open (the unspecialized pass of a generic type): emit no real body.
	public bool mOpen;

	public this()
	{
	}

	/// @brief Whether any member is required.
	public bool AnyRequired
	{
		get
		{
			for (let member in mMembers)
			{
				if (member.mRequired)
					return true;
			}
			return false;
		}
	}
}

/// A format's part in planning, as static members of a struct passed as the planner's generic
/// argument (calls are direct at compile time; beef-sharing-experiments.md Q3).
internal interface IMappingFormat
{
	/// The type attribute's name for messages: "[JsonObject]".
	static StringView Prefix { get; }
	/// The converter registration attribute's name for messages: "[JsonConverter]".
	static StringView ConverterAttributeName { get; }
	/// The per-field converter attribute's name for messages: "[JsonUseConverter]".
	static StringView UseConverterAttributeName { get; }
	/// The supported field types, for the unsupported-type message.
	static StringView SupportedTypes { get; }

	/// Whether `type` is a level of a mapped chain (carries the format's object attribute).
	static bool IsObjectLevel(Type type);
	/// Whether a value of `type` is mapped as an object (a level, or a hand-written interface).
	static bool IsObject(Type type);
	/// Whether an Object class is dispatched to its subtypes (a discriminator).
	static bool IsPolymorphic(Type type);
	/// The level's options from its attribute.
	static void ReadLevel(Type level, ref LevelOptions options);
	/// Whether the field is left out (the format's ignore attribute).
	static bool IsIgnored(FieldInfo field);
	/// The field's name (leave it empty for the naming), aliases, required flag and use-converter
	/// from the format's field attributes.
	static void ReadField(FieldInfo field, MemberPlan member);
	/// A format scalar's tag (TOML's date/times), or -1.
	static int FormatScalar(Type type);
	/// The target type of the converter registration on `declaration`, or null when it has none.
	static Type ConverterTarget(TypeDeclaration declaration);
	/// Assigns the member's role and checks it against the plan so far; claims the member's names.
	static void AssignRole(MemberPlan member, TypePlan plan, ClaimSet claims);
	/// Whether the format can hold `spec` for `member` (nesting rules); appends why not.
	static bool Allows(MemberPlan member, ValueSpec spec, String why);
	/// Whether two claims overlap: the same name in places that collide.
	static bool Overlaps(int placeA, StringView nameA, int placeB, StringView nameB);
}

/// Build errors of a typed mapping: `Runtime.FatalError`, which the compiler reports at the user's
/// attribute (beef-sharing-experiments.md Q3). Messages are self-contained: fixtures grep them.
internal static class MappingError
{
	/// @brief Stop the build for a field: `[Prefix] Owner.field: message`.
	[Comptime]
	public static void Fail(StringView prefix, StringView ownerName, StringView fieldName, StringView message)
	{
		Runtime.FatalError(scope $"{prefix} {ownerName}.{fieldName}: {message}");
	}

	/// @brief Stop the build for the type as a whole: `[Prefix] Owner: message`.
	[Comptime]
	public static void FailType(StringView prefix, StringView ownerName, StringView message)
	{
		Runtime.FatalError(scope $"{prefix} {ownerName}: {message}");
	}
}

/// The names a type's members take, by place (an XML attribute or element, a KDL property or child; one
/// place for JSON and TOML), with the format's overlap rule: two members claiming overlapping names
/// stop the build naming both fields.
internal class ClaimSet
{
	class Claim
	{
		public int mPlace;
		public String mName = new .() ~ delete _;
		public String mBy = new .() ~ delete _;

		public this()
		{
		}
	}

	List<Claim> mClaims = new .() ~ DeleteContainerAndItems!(_);
	String mPrefix = new .() ~ delete _;
	String mOwner = new .() ~ delete _;
	/// What a name is called in messages ("member", "attribute", "key").
	public String mNoun = new .("member") ~ delete _;
	/// Appended to the conflict message (where names come from).
	public String mHint = new .() ~ delete _;

	public this(StringView prefix, StringView owner)
	{
		mPrefix.Set(prefix);
		mOwner.Set(owner);
	}

	/// @brief Claim `name` in `place` for `by` (a field path or "the discriminator"), stopping the
	/// build when an earlier claim overlaps under the format's rule.
	[Comptime]
	public void Add<TFormat>(int place, StringView name, StringView by) where TFormat : IMappingFormat
	{
		for (let claim in mClaims)
		{
			if (TFormat.Overlaps(claim.mPlace, claim.mName, place, name))
			{
				let message = scope $"the {mNoun} \"{name}\" is mapped by both {claim.mBy} and {by}";
				if (!mHint.IsEmpty)
					message.AppendF(" ({})", mHint);
				MappingError.FailType(mPrefix, mOwner, message);
			}
		}
		let claim = new Claim();
		claim.mPlace = place;
		claim.mName.Set(name);
		claim.mBy.Set(by);
		mClaims.Add(claim);
	}

	/// @brief The number of claims.
	public int Count => mClaims.Count;
}

/// The shapes of corlib's generic containers (the same ten lines in every generator).
internal static class TypeShapes
{
	/// @brief The `index`th generic argument of `type` if it specializes `definition`, else null.
	public static Type GenericArg(Type type, Type definition, int index)
	{
		if (let specialized = type as SpecializedGenericType)
		{
			if (specialized.UnspecializedType == definition)
				return specialized.GetGenericArg(index);
		}
		return null;
	}

	/// @brief The T of a List<T>, or null.
	public static Type ListElement(Type type) => GenericArg(type, typeof(List<>), 0);
	/// @brief The K of a Dictionary<K, V>, or null.
	public static Type DictionaryKey(Type type) => GenericArg(type, typeof(Dictionary<,>), 0);
	/// @brief The V of a Dictionary<K, V>, or null.
	public static Type DictionaryValue(Type type) => GenericArg(type, typeof(Dictionary<,>), 1);
	/// @brief The T of a Nullable<T> (`T?`), or null.
	public static Type NullableValue(Type type) => GenericArg(type, typeof(Nullable<>), 0);

	/// @brief Whether `type` is a generic parameter or built from one (a field's type in the
	/// unspecialized pass of a generic type).
	public static bool IsOpen(Type type)
	{
		if (type == null)
			return false;
		if (type.IsGenericParam)
			return true;
		if (let specialized = type as SpecializedGenericType)
		{
			for (int i < specialized.GenericParamCount)
			{
				if (IsOpen(specialized.GetGenericArg(i)))
					return true;
			}
		}
		return false;
	}

	/// @brief Whether `type` is a 64-bit unsigned integer (read through its own path: its range does
	/// not fit an int64).
	public static bool IsUInt64(Type type)
	{
		return type.IsInteger && type.Size == 8 && !type.IsSigned;
	}

	/// @brief The kind of a scalar type, or Unsupported: bool, integers, float and double, String.
	/// Characters are not scalars (no format agrees on their text).
	public static ValueKind ScalarKind(Type type)
	{
		if (type == typeof(bool))
			return .Bool;
		if (type == typeof(char8) || type == typeof(char16) || type == typeof(char32))
			return .Unsupported;
		if (type.IsInteger)
			return .Integer;
		if (type == typeof(float) || type == typeof(double))
			return .Float;
		if (type == typeof(String))
			return .String;
		return .Unsupported;
	}

	/// @brief The kind of a dictionary key type, or Unsupported: String, integers and simple enums.
	public static ValueKind KeyKind(Type type)
	{
		if (type == typeof(String))
			return .String;
		if (type == typeof(char8) || type == typeof(char16) || type == typeof(char32) || type == typeof(bool))
			return .Unsupported;
		if (type.IsInteger)
			return .Integer;
		if (type.IsEnum && !type.IsUnion)
			return .Enum;
		return .Unsupported;
	}
}

/// Lookups over the declarations the *user's* project can see: converter registrations and the
/// subtypes of a class. **Only valid in the mixin stage**: "current" for `Type.TypeDeclarations` is the
/// project of the comptime evaluation's entry point (beef-sharing-experiments.md Q3), so these must run
/// under the [Comptime] method MappingDriver emits into the user's type, never under ApplyToType (where
/// current is the format library, and the user's declarations pass only through AlwaysVisible, which
/// fails as soon as a second project depends on the format library).
internal static class Registry
{
	/// @brief Whether `declaration` is in the user's project or a project it depends on.
	[Comptime]
	public static bool IsVisible(TypeDeclaration declaration)
	{
		return declaration.DeclaredInCurrent || declaration.DeclaredInDependency;
	}

	/// @brief The converter registered for `target` that the user's project can see, or null. Two such
	/// registrations stop the build.
	[Comptime]
	public static Type FindConverter<TFormat>(Type target) where TFormat : IMappingFormat
	{
		Type found = null;
		for (let declaration in Type.TypeDeclarations)
		{
			if (!IsVisible(declaration))
				continue;
			let registered = TFormat.ConverterTarget(declaration);
			if (registered == null || registered != target)
				continue;
			let converter = declaration.ResolvedType;
			if (found != null && found != converter)
			{
				// Named in a stable order (declarations come in no fixed order)
				let a = found.GetFullName(.. scope .());
				let b = converter.GetFullName(.. scope .());
				bool inOrder = String.Compare(a, b, false) <= 0;
				Runtime.FatalError(scope $"{TFormat.ConverterAttributeName} Both {inOrder ? a : b} and {inOrder ? b : a} are registered for {target.GetFullName(.. scope .())}. Keep one, or pick one per field with {TFormat.UseConverterAttributeName}.");
			}
			found = converter;
		}
		return found;
	}

	/// @brief The concrete object classes a field of class `type` can hold: `type` itself unless
	/// abstract, then every visible, concrete subclass the format maps (in declaration order).
	[Comptime]
	public static void SubTypes<TFormat>(Type type, List<Type> types) where TFormat : IMappingFormat
	{
		if (!type.IsAbstract && TFormat.IsObjectLevel(type))
			types.Add(type);
		for (let declaration in Type.TypeDeclarations)
		{
			if (!IsVisible(declaration))
				continue;
			let candidate = declaration.ResolvedType;
			if (candidate == null || candidate == type || candidate.IsValueType || candidate.IsInterface || candidate.IsAbstract || candidate.IsGenericParam)
				continue;
			if (TFormat.IsObjectLevel(candidate) && candidate.IsSubtypeOf(type))
				types.Add(candidate);
		}
	}
}

/// Plans a type for a format: walks its chain of mapped levels base-most first, names each serialized
/// field, builds its ValueSpec, looks up converters, lets the format assign roles and claim names, and
/// stops the build for anything that cannot be mapped. Call it in the mixin stage (MappingDriver), so
/// that converter lookups see the user's project.
internal static class Planner<TFormat> where TFormat : IMappingFormat
{
	/// @brief The plan of `type` (delete it).
	[Comptime]
	public static TypePlan Plan(Type type)
	{
		let plan = new TypePlan();
		plan.mType = type;
		type.GetFullName(plan.mOwnerName);
		for (Type level = type; level != null && TFormat.IsObjectLevel(level); level = level.IsValueType ? null : level.BaseType)
			plan.mLevels.Insert(0, level);
		let claims = scope ClaimSet(TFormat.Prefix, plan.mOwnerName);
		for (let level in plan.mLevels)
		{
			LevelOptions options = default;
			TFormat.ReadLevel(level, ref options);
			for (let field in level.GetFields())
			{
				if (!IsSerialized(level, field))
					continue;
				let member = PlanMember(plan, level, field, options);
				member.mSlot = plan.mSlots++;
				plan.mMembers.Add(member);
				TFormat.AssignRole(member, plan, claims);
			}
		}
		return plan;
	}

	/// @brief Whether `field` of `level` is mapped: declared by that level (never an inherited field or
	/// System.Object's mClassVData/mDbgAllocInfo), a public instance field, not ignored.
	[Comptime]
	public static bool IsSerialized(Type level, FieldInfo field)
	{
		return field.DeclaringType == level && !field.IsStatic && !field.IsConst && field.IsPublic && !TFormat.IsIgnored(field);
	}

	[Comptime]
	static MemberPlan PlanMember(TypePlan plan, Type level, FieldInfo field, LevelOptions options)
	{
		let member = new MemberPlan();
		member.mField = field;
		member.mLevel = level;
		member.mNaming = options.mNaming;
		TFormat.ReadField(field, member);
		if (member.mName.IsEmpty)
			Naming.Apply(field.Name, options.mNaming, member.mName);
		CheckName(plan.mOwnerName, field.Name, member.mName);
		for (let alias in member.mAliases)
			CheckName(plan.mOwnerName, field.Name, alias);
		if (TypeShapes.IsOpen(field.FieldType))
		{
			// The unspecialized pass of a generic type: nothing to check or generate until specialized
			member.mSpec = new ValueSpec();
			member.mSpec.mType = field.FieldType;
			member.mSpec.mKind = .Open;
			plan.mOpen = true;
			return member;
		}
		member.mSpec = Spec(field.FieldType, member.mUseConverter, plan.mOwnerName, field.Name);
		let why = scope String();
		if (!TFormat.Allows(member, member.mSpec, why))
			MappingError.Fail(TFormat.Prefix, plan.mOwnerName, field.Name, why);
		return member;
	}

	/// @brief Names may be any text but control characters.
	[Comptime]
	public static void CheckName(StringView ownerName, StringView fieldName, StringView name)
	{
		for (let c in name.RawChars)
		{
			if ((uint8)c < 0x20)
				MappingError.Fail(TFormat.Prefix, ownerName, fieldName, scope $"the name \"{name}\" contains a control character");
		}
	}

	/// @brief The spec of a value of `type`; a converter given for the field applies to the innermost
	/// value (inside Lists, Dictionaries and Nullables).
	[Comptime]
	public static ValueSpec Spec(Type type, Type useConverter, StringView ownerName, StringView fieldName)
	{
		let spec = new ValueSpec();
		spec.mType = type;
		Type item = null;
		if ((item = TypeShapes.ListElement(type)) != null)
		{
			spec.mKind = .List;
			spec.mItem = Spec(item, useConverter, ownerName, fieldName);
			return spec;
		}
		if ((item = TypeShapes.DictionaryValue(type)) != null)
		{
			spec.mKind = .Dictionary;
			spec.mKeyType = TypeShapes.DictionaryKey(type);
			spec.mKeyKind = TypeShapes.KeyKind(spec.mKeyType);
			if (spec.mKeyKind == .Unsupported)
				MappingError.Fail(TFormat.Prefix, ownerName, fieldName, scope $"dictionary keys must be String, integers or enums, not {spec.mKeyType.GetFullName(.. scope .())}");
			spec.mItem = Spec(item, useConverter, ownerName, fieldName);
			return spec;
		}
		if ((item = TypeShapes.NullableValue(type)) != null)
		{
			spec.mKind = .Nullable;
			spec.mItem = Spec(item, useConverter, ownerName, fieldName);
			return spec;
		}
		if (useConverter != null)
		{
			spec.mKind = .Converter;
			spec.mConverter = useConverter;
			return spec;
		}
		spec.mKind = Classify(type, out spec.mConverter, out spec.mFormatTag);
		switch (spec.mKind)
		{
		case .Unsupported:
			MappingError.Fail(TFormat.Prefix, ownerName, fieldName, scope $"fields of type {type.GetFullName(.. scope .())} are not supported. Supported: {TFormat.SupportedTypes}; also types with a converter ({TFormat.ConverterAttributeName} registration or {TFormat.UseConverterAttributeName} on the field)");
		case .Object:
			if (!type.IsValueType)
			{
				spec.mPolymorphic = TFormat.IsPolymorphic(type);
				if (!spec.mPolymorphic && type.IsAbstract)
					MappingError.Fail(TFormat.Prefix, ownerName, fieldName, scope $"{type.GetFullName(.. scope .())} is abstract: reading cannot create one. Map its subtypes, or use a converter");
			}
		default:
		}
		return spec;
	}

	/// @brief How a value of `type` is handled (not a container: Spec takes those first): scalars, a
	/// registered converter, the format's scalars, simple enums, objects, in that order.
	[Comptime]
	public static ValueKind Classify(Type type, out Type converter, out int formatTag)
	{
		converter = null;
		formatTag = -1;
		let scalar = TypeShapes.ScalarKind(type);
		if (scalar != .Unsupported)
			return scalar;
		if (type == typeof(char8) || type == typeof(char16) || type == typeof(char32))
			return .Unsupported;
		converter = Registry.FindConverter<TFormat>(type);
		if (converter != null)
			return .Converter;
		formatTag = TFormat.FormatScalar(type);
		if (formatTag >= 0)
			return .FormatScalar;
		// Simple enums only: cases with payloads have no single name
		if (type.IsEnum && !type.IsUnion)
			return .Enum;
		if (TFormat.IsObject(type))
			return .Object;
		return .Unsupported;
	}
}
