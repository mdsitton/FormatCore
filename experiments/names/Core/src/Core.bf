using System;

namespace Core;

public struct Cursor
{
	public static int Id => 1;
}

/// Emits code naming Cursor unqualified, as a careless generator would.
[AttributeUsage(.Class | .Struct)]
public struct EmitUnqualifiedAttribute : Attribute, IComptimeTypeApply
{
	[Comptime]
	public void ApplyToType(Type type)
	{
		Compiler.EmitTypeBody(type, "public static int EmittedId => Cursor.Id;\n");
	}
}

/// Emits code naming Core.Cursor qualified.
[AttributeUsage(.Class | .Struct)]
public struct EmitQualifiedAttribute : Attribute, IComptimeTypeApply
{
	[Comptime]
	public void ApplyToType(Type type)
	{
		Compiler.EmitTypeBody(type, "public static int EmittedId => Core.Cursor.Id;\n");
	}
}

/// Emits code naming global::Core.Cursor (Beef's parser knows `global::`, but neither form resolves).
[AttributeUsage(.Class | .Struct)]
public struct EmitTypeofAttribute : Attribute, IComptimeTypeApply
{
	[Comptime]
	public void ApplyToType(Type type)
	{
#if N5_GLOBAL_FIELD
		// global:: in a type position: "Member name expected"
		Compiler.EmitTypeBody(type, "static global::Core.Cursor sCursorProbe_;\npublic static int EmittedId => 1;\n");
#else
		// global:: in an expression: "Identifier not found"
		Compiler.EmitTypeBody(type, "public static int EmittedId => global::Core.Cursor.Id;\n");
#endif
	}
}

/// Same short attribute name as LibX's.
[AttributeUsage(.Class | .Struct)]
public struct ObjectAttribute : Attribute
{
}
