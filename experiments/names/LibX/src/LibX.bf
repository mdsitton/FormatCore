using System;

namespace LibX;

/// The same short name as Core.Cursor, in another library.
public struct Cursor
{
	public static int Id => 2;
}

/// The same short attribute name as Core.ObjectAttribute.
[AttributeUsage(.Class | .Struct)]
public struct ObjectAttribute : Attribute
{
}
