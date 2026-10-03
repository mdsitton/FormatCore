using System;
using Core;
using FormatLib;

namespace UserLib;

/// An [XObject] type in a library App depends on: what does it see of App's declarations?
[XObject]
public class LibThing
{
	public int count;
}

[Converter(typeof(int))]
public class UserLibIntConverter
{
}
