# Screen spike: fill the NativeActivity window with four colored quadrants.
# Language and .NET only (the payload has no cmdlet modules).
# Layouts: native_activity.h (lib/), native_window.h and hardware_buffer.h
# (frameworks/native bfcf7507). Callback table zeroed by NativeCode's
# constructor (frameworks/base 299fe6f5 android_app_NativeActivity.cpp:121).
$ErrorActionPreference = 'Stop'
$ab = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly([Reflection.AssemblyName]::new('PwshScreenSpike'), [Reflection.Emit.AssemblyBuilderAccess]::Run)
$mb = $ab.DefineDynamicModule('PwshScreenSpike')

$nt = $mb.DefineType('Spike.Native', [Reflection.TypeAttributes]'Public,Abstract,Sealed')
function Add-Import([string] $Name, [string] $Library, [type] $Return, [type[]] $Parameters) {
    $m = $nt.DefinePInvokeMethod($Name, $Library, [Reflection.MethodAttributes]'Public,Static,PinvokeImpl,HideBySig',
        [Reflection.CallingConventions]::Standard, $Return, $Parameters,
        [Runtime.InteropServices.CallingConvention]::Cdecl, [Runtime.InteropServices.CharSet]::Ansi)
    $m.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
}
Add-Import '__android_log_write' 'liblog.so' ([int]) @([int], [string], [string])
Add-Import 'ANativeWindow_setBuffersGeometry' 'libandroid.so' ([int]) @([IntPtr], [int], [int], [int])
Add-Import 'ANativeWindow_lock' 'libandroid.so' ([int]) @([IntPtr], [IntPtr], [IntPtr])
Add-Import 'ANativeWindow_unlockAndPost' 'libandroid.so' ([int]) @([IntPtr])
$native = $nt.CreateType()

# void (*)(ANativeActivity*, ANativeWindow*)
$dt = $mb.DefineType('Spike.WindowCallback', [Reflection.TypeAttributes]'Public,Sealed', [MulticastDelegate])
$ctor = $dt.DefineConstructor([Reflection.MethodAttributes]'Public,HideBySig,SpecialName,RTSpecialName', [Reflection.CallingConventions]::Standard, [type[]]@([object], [IntPtr]))
$ctor.SetImplementationFlags([Reflection.MethodImplAttributes]'Runtime,Managed')
$inv = $dt.DefineMethod('Invoke', [Reflection.MethodAttributes]'Public,HideBySig,NewSlot,Virtual', [void], [type[]]@([IntPtr], [IntPtr]))
$inv.SetImplementationFlags([Reflection.MethodImplAttributes]'Runtime,Managed')
$callbackType = $dt.CreateType()

$global:SpikeNative = $native
function global:SpikeLog([string] $Text) { [void]$global:SpikeNative::__android_log_write(4, 'Pwsh', "SCREEN $Text") }
function global:Rgba([byte] $R, [byte] $G, [byte] $B) { [BitConverter]::ToInt32([byte[]]@($R, $G, $B, 255), 0) }

function global:Fill-Window([IntPtr] $Window) {
    $n = $global:SpikeNative
    $rc = $n::ANativeWindow_setBuffersGeometry($Window, 0, 0, 1)   # WINDOW_FORMAT_RGBA_8888
    $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(64)       # ANativeWindow_Buffer: 44 or 48 bytes
    try {
        $rc = $n::ANativeWindow_lock($Window, $buf, [IntPtr]::Zero)
        if ($rc -ne 0) { SpikeLog "lock failed $rc"; return }
        $w = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 0)
        $h = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 4)
        $stride = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 8)
        $format = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 12)
        $bits = [Runtime.InteropServices.Marshal]::ReadIntPtr($buf, 16)
        $colors = @((Rgba 255 0 0), (Rgba 0 255 0), (Rgba 0 0 255), (Rgba 255 255 255))   # TL TR BL BR
        $top = [int[]]::new($stride); $bottom = [int[]]::new($stride)
        $half = [int]($w / 2)
        [Array]::Fill($top, $colors[0], 0, $half); [Array]::Fill($top, $colors[1], $half, $stride - $half)
        [Array]::Fill($bottom, $colors[2], 0, $half); [Array]::Fill($bottom, $colors[3], $half, $stride - $half)
        for ($y = 0; $y -lt $h; $y++) {
            $row = if ($y -lt ($h / 2)) { $top } else { $bottom }
            [Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]::Add($bits, $y * $stride * 4), $stride)
        }
        # Read one cell back from the locked buffer before posting it.
        $probe = [Runtime.InteropServices.Marshal]::ReadInt32($bits, (([int]($h / 4)) * $stride + [int]($w / 4)) * 4)
        $rc = $n::ANativeWindow_unlockAndPost($Window)
        SpikeLog ("filled {0}x{1} stride {2} format {3} probeTL 0x{4:x8} post {5}" -f $w, $h, $stride, $format, $probe, $rc)
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
}

$handler = {
    param([IntPtr] $Activity, [IntPtr] $Window)
    try { Fill-Window $Window } catch { SpikeLog ("callback threw " + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message) }
}
$global:SpikeCreated = [Management.Automation.LanguagePrimitives]::ConvertTo($handler, $callbackType)
$global:SpikeRedraw = [Management.Automation.LanguagePrimitives]::ConvertTo($handler, $callbackType)
$created = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($global:SpikeCreated)
$redraw = [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($global:SpikeRedraw)

$callbacks = [Runtime.InteropServices.Marshal]::ReadIntPtr([IntPtr]$NativeActivityHandle, 0)
$p = [IntPtr]::Size
[Runtime.InteropServices.Marshal]::WriteIntPtr($callbacks, 7 * $p, $created)   # onNativeWindowCreated
[Runtime.InteropServices.Marshal]::WriteIntPtr($callbacks, 9 * $p, $redraw)    # onNativeWindowRedrawNeeded
SpikeLog "callbacks installed"
$global:Gate2d = 0x5C5C5C5C
