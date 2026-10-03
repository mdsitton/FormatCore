using System;
using FormatCore.Mapping;

namespace ToyFormat;

/// Generates ToyRead and ToyWrite for a class or struct, through FormatCore's mapping framework.
[AttributeUsage(.Class | .Struct)]
public struct ToyObjectAttribute : Attribute, IComptimeTypeApply
{
	/// How field names (and the enum cases of the level's fields) become member names.
	public NamingPolicy Naming;

	/// Also emit `ToyRegistryNow` (the converters the mixin stage finds, the fixed lookup) and
	/// `ToyRegistryAtApply` (what the siblings' old lookup finds inside ApplyToType), for the registry
	/// regression workspace.
	public bool ShowRegistry;

	[Comptime]
	public void ApplyToType(Type type)
	{
		ToyCodeGen.Emit(type, this);
	}
}

/// Maps a field to `name`.
[AttributeUsage(.Field)]
public struct ToyNameAttribute : Attribute
{
	public String mName;

	public this(String name)
	{
		mName = name;
	}
}

/// Also accepts `name` when reading (repeatable); writing renames it.
[AttributeUsage(.Field)]
public struct ToyAliasAttribute : Attribute
{
	public String mName;

	public this(String name)
	{
		mName = name;
	}
}

[AttributeUsage(.Field)]
public struct ToyIgnoreAttribute : Attribute
{
}

[AttributeUsage(.Field)]
public struct ToyRequiredAttribute : Attribute
{
}

/// Registers the converter it is placed on for every field and item of type `target`.
[AttributeUsage(.Class | .Struct)]
public struct ToyConverterAttribute : Attribute
{
	public Type mTarget;

	public this(Type target)
	{
		mTarget = target;
	}
}

/// Reads and writes one field with `converter`.
[AttributeUsage(.Field)]
public struct ToyUseConverterAttribute : Attribute
{
	public Type mConverter;

	public this(Type converter)
	{
		mConverter = converter;
	}
}

/// What [ToyObject] generates.
public interface IToySerializable
{
	Result<void, ToyError> ToyRead(ToyNode node, ITypedAllocator allocator = null) mut;
	void ToyWrite(ToyNode node);
}

/// A converter for one type T.
public interface IToyConverter<T>
{
	static Result<void, ToyError> Read(ToyNode node, ref T target);
	static void Write(T value, ToyNode node);
}
