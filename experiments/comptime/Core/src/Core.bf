using System;
using System.Collections;
using System.Reflection;

namespace Core;

/// Q5: a shared attribute with a String member, read by the format library from user fields.
[AttributeUsage(.Field)]
public struct SerialNameAttribute : Attribute
{
	public String mName;

	public this(String name)
	{
		mName = name;
	}
}

/// Q2: converter registration, found through Type.TypeDeclarations.
[AttributeUsage(.Class | .Struct)]
public struct ConverterAttribute : Attribute
{
	public Type mTarget;

	public this(Type target)
	{
		mTarget = target;
	}
}

/// One hop: a Core attribute (IComptimeTypeApply) applied directly to an App type.
[AttributeUsage(.Class | .Struct)]
public struct CoreDirectAttribute : Attribute, IComptimeTypeApply
{
	[Comptime]
	public void ApplyToType(Type type)
	{
		let decls = CoreRegistry.Describe(.. scope .());
		Compiler.EmitTypeBody(type, scope $"public static StringView CoreDirect => \"Core.CoreDirectAttribute.ApplyToType on {type.GetFullName(.. scope .())} CallerType={Compiler.CallerType} {decls}\";\n");
	}
}

/// Re-enters comptime from the user type: emits an [OnCompile] method into it that does the work, so
/// the evaluation's entry point (and so "current" for TypeDeclarations) is the user type's project.
[AttributeUsage(.Class | .Struct)]
public struct CoreDeferAttribute : Attribute, IComptimeTypeApply
{
	[Comptime]
	public void ApplyToType(Type type)
	{
#if DEFER_SIMPLE
		Compiler.EmitTypeBody(type, """
			[System.OnCompile(.TypeInit), System.Comptime]
			static void CoreDeferGen_()
			{
				System.Compiler.EmitTypeBody(typeof(Self), "public static System.StringView Deferred => \\"simple\\";\\n");
			}
			""");
		return;
#endif
		Compiler.EmitTypeBody(type, """
			[System.OnCompile(.TypeInit), System.Comptime]
			static void CoreDeferGen_()
			{
				System.Compiler.EmitTypeBody(typeof(Self), scope $"public static System.StringView Deferred => {Core.Literal.Append(.. scope .(), Core.CoreRegistry.Describe(.. scope .()))};\\n");
			}
			""");
	}
}

/// One hop, IOnTypeInit form.
[AttributeUsage(.Class | .Struct)]
public struct CoreInitAttribute : Attribute, IOnTypeInit
{
	[Comptime]
	public void OnTypeInit(Type type, Self* prev)
	{
		Compiler.EmitTypeBody(type, scope $"public static StringView CoreInit => \"Core.CoreInitAttribute.OnTypeInit on {type.GetFullName(.. scope .())}\";\n");
	}
}

/// Q3: an attribute interface a generic planner reads through a type parameter.
public interface IRoleAttribute
{
	StringView Role { get; }
}

/// Q3: the format a planner is specialized on, called through static interface members at comptime.
public interface IMappingFormat
{
	static StringView FormatName { get; }
	static void AssignRole(FieldInfo field, String outRole);
}

/// Q4: plan objects allocated in Core, used and freed by the format library.
public interface IPlanVisitor
{
	void Visit(MemberPlan plan);
}

public class MemberPlan
{
	public String mName ~ delete _;
	public String mRole ~ delete _;

	public this()
	{
		mName = new .();
		mRole = new .();
	}

	public virtual void Describe(String output)
	{
		output.AppendF("{}={}", mName, mRole);
	}

	public void Accept(IPlanVisitor visitor)
	{
		visitor.Visit(this);
	}
}

/// Q6: a static field mutated during comptime.
public static class PlanCache
{
	public static int sPlans;
}

/// Q8: a helper used both at comptime (by FormatLib) and at runtime (by App): not [Comptime].
public static class Naming
{
	public static void Kebab(StringView name, String output)
	{
		for (int i < name.Length)
		{
			char8 c = name[i];
			if (c.IsUpper)
			{
				if (i > 0)
					output.Append('-');
				output.Append(c.ToLower);
			}
			else
				output.Append(c);
		}
	}
}

public static class Literal
{
	/// A quoted Beef string literal of `text`.
	public static void Append(String output, StringView text)
	{
		output.Append('"');
		for (let c in text)
		{
			if (c == '"' || c == '\\')
				output.Append('\\');
			output.Append(c);
		}
		output.Append('"');
	}
}

/// Q3: a generic comptime planner, specialized on the format library's format and attribute types.
public static class Planner<TFormat, TRoleAttr> where TFormat : IMappingFormat where TRoleAttr : Attribute, IRoleAttribute
{
	/// Version marker for the incremental-rebuild test (Q7).
	public const String Version = "planner-v1";

	[Comptime]
	public static void Plan(Type type, List<MemberPlan> plans)
	{
		for (let field in type.GetFields())
		{
			// GetFields includes inherited fields, System.Object's mClassVData (and mDbgAllocInfo in Debug) too
			if (!field.IsInstanceField || field.DeclaringType == typeof(Object))
				continue;
			CoreChecks.CheckSupported(type, field);
			let plan = new MemberPlan();
			if (field.GetCustomAttribute<SerialNameAttribute>() case .Ok(let serialName))
				plan.mName.Append(serialName.mName);
			else
				plan.mName.Append(field.Name);
			// A generic attribute type: HasCustomAttribute<TRoleAttr> and GetCustomAttribute<TRoleAttr>
			if (field.HasCustomAttribute<TRoleAttr>() && field.GetCustomAttribute<TRoleAttr>() case .Ok(let roleAttr))
				plan.mRole.AppendF("{}(via {})", roleAttr.Role, typeof(TRoleAttr).GetName(.. scope .()));
			else
				TFormat.AssignRole(field, plan.mRole);
			plans.Add(plan);
		}
		PlanCache.sPlans++;
	}

	[Comptime]
	public static StringView FormatName => TFormat.FormatName;
}

public static class CoreChecks
{
	/// Q9: a build error raised two frames into Core.
	[Comptime]
	public static void CheckSupported(Type owner, FieldInfo field)
	{
#if FIXTURE_GENERIC_PARAM
		// Q11: is ApplyToType also run on the unspecialized Box<T>?
		if (field.FieldType.IsGenericParam)
			Runtime.FatalError(scope $"[Core] {owner.GetFullName(.. scope .())}.{field.Name}: generic parameter field seen");
#endif
		if (field.FieldType.IsPointer)
			Runtime.FatalError(scope $"[Core] {owner.GetFullName(.. scope .())}.{field.Name}: pointer fields are not supported");
	}
}

/// Q2: converter lookup through Type.TypeDeclarations from Core code.
public static class CoreRegistry
{
	[Comptime]
	public static void Describe(String output)
	{
		output.AppendF("ProjectName@Core={} CallerProject@Core={} decls@Core:[", Compiler.ProjectName, Compiler.CallerProject);
		DescribeDecls(output);
		output.Append("]");
	}

	/// The same, as a statement for Compiler.Mixin in generated code (evaluated in the user type's context).
	[Comptime]
	public static String DescribeAsCode()
	{
		let text = Describe(.. scope String());
		let code = scope String();
		code.Append("return ");
		Literal.Append(code, text);
		code.Append(";");
		return code;
	}

	[Comptime]
	public static void DescribeDecls(String output)
	{
		for (let declaration in Type.TypeDeclarations)
		{
			if (!declaration.HasCustomAttribute<ConverterAttribute>())
				continue;
			declaration.GetFullName(output);
			output.Append('{');
			if (declaration.DeclaredInCurrent)
				output.Append("Cur ");
			if (declaration.DeclaredInDependency)
				output.Append("Dep ");
			if (declaration.DeclaredInDependent)
				output.Append("Dependent ");
			if (declaration.AlwaysVisible)
				output.Append("Always ");
			if (declaration.SometimesVisible)
				output.Append("Sometimes");
			output.Append("} ");
		}
	}
}

[Converter(typeof(int))]
public class CoreIntConverter
{
}
