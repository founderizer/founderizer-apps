#:property PublishAot=false
#:property RestorePackagesWithLockFile=false
// The reader of a built release (windows-app-plan-v2.md, piece T1, test 2, and section 13): the values that the
// compiler put into a built .NET file, read from its metadata, so that no search of its text can miss one. build-release.ps1
// runs it with the release SDK, in this folder:
//
//   dotnet run --file read-constants.cs -- <file.dll> <Namespace.Type.Field>...
//
// It prints <Namespace.Type.Field>=<value> for each name, true or false for a bool and the text of a string, and ends
// with exit 1 when the file is no .NET file or has no such constant.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;

if (args.Length < 2)
{
    Console.Error.WriteLine("usage: read-constants.cs <file.dll> <Namespace.Type.Field>...");
    return 2;
}
using var stream = File.OpenRead(args[0]);
using var file = new PEReader(stream);
if (!file.HasMetadata)
{
    Console.Error.WriteLine($"{args[0]} is no .NET file");
    return 1;
}
var metadata = file.GetMetadataReader();
var constants = new Dictionary<string, string>(StringComparer.Ordinal);
foreach (var typeHandle in metadata.TypeDefinitions)
{
    var type = metadata.GetTypeDefinition(typeHandle);
    var typeName = metadata.GetString(type.Namespace) + "." + metadata.GetString(type.Name);
    foreach (var fieldHandle in type.GetFields())
    {
        var field = metadata.GetFieldDefinition(fieldHandle);
        var constantHandle = field.GetDefaultValue();
        if (constantHandle.IsNil) continue;
        var constant = metadata.GetConstant(constantHandle);
        var blob = metadata.GetBlobReader(constant.Value);
        string? value = constant.TypeCode switch
        {
            ConstantTypeCode.Boolean => blob.ReadBoolean() ? "true" : "false",
            ConstantTypeCode.String => blob.ReadUTF16(blob.Length),
            _ => null,
        };
        if (value is not null) constants[typeName + "." + metadata.GetString(field.Name)] = value;
    }
}
int code = 0;
foreach (var name in args[1..])
{
    if (constants.TryGetValue(name, out var value))
    {
        Console.WriteLine($"{name}={value}");
    }
    else
    {
        Console.Error.WriteLine($"{args[0]} has no constant {name}");
        code = 1;
    }
}
return code;
