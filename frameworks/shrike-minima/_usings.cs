global using System;
global using System.Buffers;
global using System.Buffers.Binary;
global using System.Buffers.Text;
global using System.Collections.Concurrent;
global using System.Runtime.CompilerServices;
global using System.Runtime.InteropServices;
global using System.Text.Json.Serialization;

global using Microsoft.Extensions.ObjectPool;

global using static Shrike.ProcessorArchDependant;
global using static Shrike.Native;
global using static Shrike.HeaderParsing;
global using static Shrike.HashUtils;