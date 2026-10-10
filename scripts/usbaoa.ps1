#Requires -Version 7.4
<#
.SYNOPSIS
Android Open Accessory negotiation and a synchronous accessory bulk Stream.
.DESCRIPTION
Ported from Kokoro-Hexagon tools/UsbAoa.ps1 at
c7f93c3db4c9b900a9daf9e959f84f2c33189a6a, read with git show.
Donor SHA-256: 9E92F8B862FE7E78BBCFBCD1233E69D2BDA4D94FEB1686E42E757C9B4CC73996.
The donor's GET_PROTOCOL, SEND_STRING and START_ACCESSORY sequence is retained.
The old handle is closed before observing accessory re-enumeration. Windows
device notifications replace the donor's timed polling. Native callbacks signal
a wait handle through emitted IL; they never enter a PowerShell runspace.

Windows ABI source: microsoft/win32metadata
76c04c2021ef4a831a6f1e06d9566002d746139b, RecompiledIdlHeaders:
um/cfgmgr32.h SHA-256 986A02619C81FFE5ACEF63E761BD41E25E3A4190AB1840C72600319342D4AA67;
um/winusb.h SHA-256 7229B8E632D6D103DA2FF8B47323F4764E6A898CF923C44A8667AF92E16A5208;
shared/winusbio.h SHA-256 CCC1D42D642C5F0BE7629ADAF11D134CAEC354C8747D4F2CC10A3785B1F42017;
shared/usb.h SHA-256 F30844B00A1452F59E84731816CA32589875F6A2B1AEBC3F387C5978432FDF48.
AOA protocol: https://source.android.com/docs/core/interaction/accessories/aoa

Call directly for command output or through & with -Api for result objects.
The stream command always returns System.IO.Stream; its owner must Dispose it.
Close adb.exe and adb.ps1 connection holders before negotiating. Accessory
bulk I/O additionally requires a WinUSB driver on the accessory interface and
an Android application opening that accessory. No driver is installed here.
Synchronous I/O and disposal must not run concurrently. Android-host transport
and bulk traffic on a device remain separate acceptance checks.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'devices', 'protocol', 'start', 'stream')]
    [string] $Command = 'devices',
    [string] $Device = '',
    [switch] $Api,
    [string] $Manufacturer = 'MansfieldPlumbing',
    [string] $Model = 'Pwsh',
    [string] $Description = 'PowerShell accessory transport',
    [string] $Version = '1',
    [string] $Uri = '',
    [string] $Serial = 'PwshAccessory',
    [ValidateRange(0, 30000)][int] $WaitMilliseconds = 5000
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

class AoaNative {
    static [Type] $Methods
    static [Delegate] $ArrivalCallback

    static [Type] GetMethods() {
        if ($null -ne [AoaNative]::Methods) { return [AoaNative]::Methods }
        $name = 'AoaNative' + [Guid]::NewGuid().ToString('N')
        $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
            [Reflection.AssemblyName]::new($name), [Reflection.Emit.AssemblyBuilderAccess]::Run)
        $module = $assembly.DefineDynamicModule($name)
        $type = $module.DefineType($name, [Reflection.TypeAttributes]'Public,Abstract,Sealed')
        $signatures = @(
            @('winusb.dll', 'WinUsb_Initialize', [int], @([IntPtr], [IntPtr])),
            @('winusb.dll', 'WinUsb_Free', [int], @([IntPtr])),
            # WINUSB_SETUP_PACKET is a packed eight-byte value, passed by value.
            @('winusb.dll', 'WinUsb_ControlTransfer', [int], @([IntPtr], [uint64], [IntPtr], [uint32], [IntPtr], [IntPtr])),
            @('winusb.dll', 'WinUsb_QueryInterfaceSettings', [int], @([IntPtr], [byte], [IntPtr])),
            @('winusb.dll', 'WinUsb_QueryPipe', [int], @([IntPtr], [byte], [byte], [IntPtr])),
            @('winusb.dll', 'WinUsb_ReadPipe', [int], @([IntPtr], [byte], [IntPtr], [uint32], [IntPtr], [IntPtr])),
            @('winusb.dll', 'WinUsb_WritePipe', [int], @([IntPtr], [byte], [IntPtr], [uint32], [IntPtr], [IntPtr])),
            @('cfgmgr32.dll', 'CM_Register_Notification', [uint32], @([IntPtr], [IntPtr], [IntPtr], [IntPtr])),
            @('cfgmgr32.dll', 'CM_Unregister_Notification', [uint32], @([IntPtr]))
        )
        foreach ($signature in $signatures) {
            $method = $type.DefinePInvokeMethod($signature[1], $signature[0], $signature[1],
                [Reflection.MethodAttributes]'Public,Static,PinvokeImpl',
                [Reflection.CallingConventions]::Standard, $signature[2], [Type[]]$signature[3],
                [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::None)
            $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
            $attribute = [Reflection.Emit.CustomAttributeBuilder]::new(
                [Runtime.InteropServices.DllImportAttribute].GetConstructor(@([string])),
                [object[]]@($signature[0]),
                [Reflection.FieldInfo[]]@([Runtime.InteropServices.DllImportAttribute].GetField('SetLastError')),
                [object[]]@($true))
            $method.SetCustomAttribute($attribute)
        }
        # PCM_NOTIFY_CALLBACK returns DWORD and accepts five pointer/DWORD
        # arguments. Its context owns a GCHandle to an AutoResetEvent. Only IL
        # runs on the native notification thread; unregister precedes freeing it.
        $callbackArguments = [Type[]]@([IntPtr], [IntPtr], [uint32], [IntPtr], [uint32])
        $callbackMethod = $type.DefineMethod('Notify', [Reflection.MethodAttributes]'Public,Static', [uint32], $callbackArguments)
        $il = $callbackMethod.GetILGenerator()
        $handleLocal = $il.DeclareLocal([Runtime.InteropServices.GCHandle])
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
        $il.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.GCHandle].GetMethod('FromIntPtr', [Type[]]@([IntPtr])))
        $il.Emit([Reflection.Emit.OpCodes]::Stloc, $handleLocal)
        $il.Emit([Reflection.Emit.OpCodes]::Ldloca, $handleLocal)
        $il.Emit([Reflection.Emit.OpCodes]::Call, [Runtime.InteropServices.GCHandle].GetProperty('Target').GetMethod)
        $il.Emit([Reflection.Emit.OpCodes]::Castclass, [Threading.AutoResetEvent])
        $il.Emit([Reflection.Emit.OpCodes]::Callvirt, [Threading.EventWaitHandle].GetMethod('Set', [Type[]]::new(0)))
        $il.Emit([Reflection.Emit.OpCodes]::Pop)
        $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
        $il.Emit([Reflection.Emit.OpCodes]::Ret)
        $delegateBuilder = $module.DefineType($name + 'Callback',
            [Reflection.TypeAttributes]'Public,Sealed', [MulticastDelegate])
        $constructor = $delegateBuilder.DefineConstructor(
            [Reflection.MethodAttributes]'Public,HideBySig,RTSpecialName',
            [Reflection.CallingConventions]::Standard, @([object], [IntPtr]))
        $constructor.SetImplementationFlags([Reflection.MethodImplAttributes]'Runtime,Managed')
        $invoke = $delegateBuilder.DefineMethod('Invoke',
            [Reflection.MethodAttributes]'Public,HideBySig,NewSlot,Virtual', [uint32], $callbackArguments)
        $invoke.SetImplementationFlags([Reflection.MethodImplAttributes]'Runtime,Managed')
        $delegateBuilder.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new(
            [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(@([Runtime.InteropServices.CallingConvention])),
            [object[]]@([Runtime.InteropServices.CallingConvention]::Winapi)))
        $delegateType = $delegateBuilder.CreateType()
        [AoaNative]::Methods = $type.CreateType()
        [AoaNative]::ArrivalCallback = [Delegate]::CreateDelegate($delegateType, [AoaNative]::Methods.GetMethod('Notify'))
        return [AoaNative]::Methods
    }
}

class AoaArrival : IDisposable {
    [Threading.AutoResetEvent] $Signal
    [Runtime.InteropServices.GCHandle] $Context
    [IntPtr] $Registration = [IntPtr]::Zero
    [Type] $Native

    AoaArrival() {
        $this.Native = [AoaNative]::GetMethods()
        $this.Signal = [Threading.AutoResetEvent]::new($false)
        $this.Context = [Runtime.InteropServices.GCHandle]::Alloc($this.Signal)
        # cfgmgr32.h: 16-byte prefix plus WCHAR InstanceId[200] union.
        # All interface classes: Flags=1, FilterType=0, zero ClassGuid.
        $filter = [byte[]]::new(416)
        [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]416), 0, $filter, 0, 4)
        $filter[4] = 1
        $registrationOut = [IntPtr[]]::new(1)
        $filterPin = [Runtime.InteropServices.GCHandle]::Alloc($filter, 'Pinned')
        $registrationPin = [Runtime.InteropServices.GCHandle]::Alloc($registrationOut, 'Pinned')
        try {
            $nativeType = $this.Native
            $result = $nativeType::CM_Register_Notification($filterPin.AddrOfPinnedObject(),
                [Runtime.InteropServices.GCHandle]::ToIntPtr($this.Context),
                [Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate([AoaNative]::ArrivalCallback),
                $registrationPin.AddrOfPinnedObject())
            if ($result -ne 0) { throw "CM_Register_Notification failed: CONFIGRET $result." }
            $this.Registration = $registrationOut[0]
        }
        catch { $this.Dispose(); throw }
        finally { $filterPin.Free(); $registrationPin.Free() }
    }

    [void] Dispose() {
        if ($this.Registration -ne [IntPtr]::Zero) {
            $nativeType = $this.Native
            $result = $nativeType::CM_Unregister_Notification($this.Registration)
            if ($result -ne 0) { throw "CM_Unregister_Notification failed: CONFIGRET $result; callback context retained." }
            $this.Registration = [IntPtr]::Zero
        }
        if ($this.Context.IsAllocated) { $this.Context.Free() }
        if ($null -ne $this.Signal) { $this.Signal.Dispose(); $this.Signal = $null }
    }
}

class AoaUsbHandle : IDisposable {
    [Type] $Native
    [Microsoft.Win32.SafeHandles.SafeFileHandle] $File
    [IntPtr] $Usb = [IntPtr]::Zero

    AoaUsbHandle([string] $door) {
        $this.Native = [AoaNative]::GetMethods()
        $this.File = [IO.File]::OpenHandle($door, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite, [IO.FileOptions]::Asynchronous)
        $usbOut = [IntPtr[]]::new(1)
        $usbPin = [Runtime.InteropServices.GCHandle]::Alloc($usbOut, 'Pinned')
        try {
            $nativeType = $this.Native
            $ok = $nativeType::WinUsb_Initialize($this.File.DangerousGetHandle(), $usbPin.AddrOfPinnedObject())
            $nativeError = [Runtime.InteropServices.Marshal]::GetLastPInvokeError()
            if ($ok -eq 0) { throw [ComponentModel.Win32Exception]::new($nativeError, 'WinUsb_Initialize: close competing ADB holders and check the interface driver.') }
            $this.Usb = $usbOut[0]
        }
        catch { $this.Dispose(); throw }
        finally { $usbPin.Free() }
    }

    [object] Control([byte] $requestType, [byte] $request, [uint16] $index, [byte[]] $buffer) {
        if ($buffer.Length -gt 256) { throw 'AOA control data exceeds 256 bytes.' }
        $setup = [uint64]$requestType -bor ([uint64]$request -shl 8) -bor
            ([uint64]$index -shl 32) -bor ([uint64]$buffer.Length -shl 48)
        $transferred = [uint32[]]::new(1)
        $bufferPin = [Runtime.InteropServices.GCHandle]::Alloc($buffer, 'Pinned')
        $countPin = [Runtime.InteropServices.GCHandle]::Alloc($transferred, 'Pinned')
        try {
            $nativeType = $this.Native
            $ok = $nativeType::WinUsb_ControlTransfer($this.Usb, $setup, $bufferPin.AddrOfPinnedObject(),
                [uint32]$buffer.Length, $countPin.AddrOfPinnedObject(), [IntPtr]::Zero)
            $nativeError = [Runtime.InteropServices.Marshal]::GetLastPInvokeError()
            return [pscustomobject]@{ Accepted = $ok -ne 0; Error = $nativeError; Transferred = $transferred[0]; Data = $buffer }
        }
        finally { $countPin.Free(); $bufferPin.Free() }
    }

    [void] Dispose() {
        if ($this.Usb -ne [IntPtr]::Zero) {
            $nativeType = $this.Native
            [void]$nativeType::WinUsb_Free($this.Usb)
            $this.Usb = [IntPtr]::Zero
        }
        if ($null -ne $this.File) { $this.File.Dispose(); $this.File = $null }
    }
}

class AoaBulkStream : IO.Stream {
    [AoaUsbHandle] $Connection
    [byte] $InputPipe
    [byte] $OutputPipe

    AoaBulkStream([string] $door) {
        $this.Connection = [AoaUsbHandle]::new($door)
        $descriptor = [byte[]]::new(9)
        $pipeInfo = [byte[]]::new(12)
        $descriptorPin = [Runtime.InteropServices.GCHandle]::Alloc($descriptor, 'Pinned')
        $pipePin = [Runtime.InteropServices.GCHandle]::Alloc($pipeInfo, 'Pinned')
        try {
            $nativeType = $this.Connection.Native
            $ok = $nativeType::WinUsb_QueryInterfaceSettings($this.Connection.Usb, [byte]0, $descriptorPin.AddrOfPinnedObject())
            $nativeError = [Runtime.InteropServices.Marshal]::GetLastPInvokeError()
            if ($ok -eq 0) { throw [ComponentModel.Win32Exception]::new($nativeError) }
            # AOA bulk interface: class/subclass/protocol ff/ff/00. ADB's
            # ff/42/01 interface must never be mistaken for the accessory pipe.
            if ($descriptor[5] -ne 255 -or $descriptor[6] -ne 255 -or $descriptor[7] -ne 0) {
                throw 'The selected interface is not an AOA accessory bulk interface (ff/ff/00).'
            }
            for ($pipeIndex = 0; $pipeIndex -lt $descriptor[4]; $pipeIndex++) {
                $ok = $nativeType::WinUsb_QueryPipe($this.Connection.Usb, [byte]0, [byte]$pipeIndex, $pipePin.AddrOfPinnedObject())
                $nativeError = [Runtime.InteropServices.Marshal]::GetLastPInvokeError()
                if ($ok -eq 0) { throw [ComponentModel.Win32Exception]::new($nativeError) }
                if ([BitConverter]::ToInt32($pipeInfo, 0) -ne 2) { continue }
                if (($pipeInfo[4] -band 128) -ne 0) { $this.InputPipe = $pipeInfo[4] }
                else { $this.OutputPipe = $pipeInfo[4] }
            }
            if ($this.InputPipe -eq 0 -or $this.OutputPipe -eq 0) { throw 'The accessory interface lacks a bulk input/output pair.' }
        }
        catch { $this.Connection.Dispose(); $this.Connection = $null; throw }
        finally { $pipePin.Free(); $descriptorPin.Free() }
    }

    [bool] get_CanRead() { return $null -ne $this.Connection }
    [bool] get_CanWrite() { return $null -ne $this.Connection }
    [bool] get_CanSeek() { return $false }
    [long] get_Length() { throw [NotSupportedException]::new() }
    [long] get_Position() { throw [NotSupportedException]::new() }
    [void] set_Position([long] $value) { throw [NotSupportedException]::new() }
    [long] Seek([long] $offset, [IO.SeekOrigin] $origin) { throw [NotSupportedException]::new() }
    [void] SetLength([long] $value) { throw [NotSupportedException]::new() }
    [void] Flush() { if ($null -eq $this.Connection) { throw [ObjectDisposedException]::new('AoaBulkStream') } }

    [int] Read([byte[]] $buffer, [int] $offset, [int] $count) {
        return $this.Transfer($buffer, $offset, $count, $false)
    }

    [void] Write([byte[]] $buffer, [int] $offset, [int] $count) {
        $remaining = $count
        # Validate even zero-length writes and the complete caller range.
        $this.ValidateBuffer($buffer, $offset, $count)
        while ($remaining -gt 0) {
            $written = $this.Transfer($buffer, $offset, $remaining, $true)
            if ($written -eq 0) { throw [IO.IOException]::new('Accessory write made no progress.') }
            $offset += $written; $remaining -= $written
        }
    }

    hidden [void] ValidateBuffer([byte[]] $buffer, [int] $offset, [int] $count) {
        if ($null -eq $this.Connection) { throw [ObjectDisposedException]::new('AoaBulkStream') }
        if ($null -eq $buffer) { throw [ArgumentNullException]::new('buffer') }
        if ($offset -lt 0 -or $count -lt 0 -or $offset -gt $buffer.Length - $count) {
            throw [ArgumentOutOfRangeException]::new('offset/count')
        }
    }

    hidden [int] Transfer([byte[]] $buffer, [int] $offset, [int] $count, [bool] $writing) {
        $this.ValidateBuffer($buffer, $offset, $count)
        if ($count -eq 0) { return 0 }
        $chunk = [Math]::Min($count, 65536)
        $bufferPin = [Runtime.InteropServices.GCHandle]::Alloc($buffer, 'Pinned')
        $transferred = [uint32[]]::new(1)
        $countPin = [Runtime.InteropServices.GCHandle]::Alloc($transferred, 'Pinned')
        try {
            $nativeType = $this.Connection.Native
            $address = [IntPtr]::Add($bufferPin.AddrOfPinnedObject(), $offset)
            if ($writing) {
                $ok = $nativeType::WinUsb_WritePipe($this.Connection.Usb, $this.OutputPipe, $address,
                    [uint32]$chunk, $countPin.AddrOfPinnedObject(), [IntPtr]::Zero)
            }
            else {
                $ok = $nativeType::WinUsb_ReadPipe($this.Connection.Usb, $this.InputPipe, $address,
                    [uint32]$chunk, $countPin.AddrOfPinnedObject(), [IntPtr]::Zero)
            }
            $nativeError = [Runtime.InteropServices.Marshal]::GetLastPInvokeError()
            if ($ok -eq 0) { throw [ComponentModel.Win32Exception]::new($nativeError) }
            if ($transferred[0] -gt $chunk) { throw [IO.IOException]::new('WinUSB returned an invalid byte count.') }
            return [int]$transferred[0]
        }
        finally { $countPin.Free(); $bufferPin.Free() }
    }

    [void] Dispose([bool] $disposing) {
        if ($null -ne $this.Connection) { $this.Connection.Dispose(); $this.Connection = $null }
    }
}

function Get-AoaDevice {
    # The donor's ADB interface discovery, plus present accessory devices.
    $present = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    $deviceClassRoot = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceClasses\{F72FE0D4-CBCB-407D-8814-9ED673D0DD6B}'
    $found = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $deviceClassRoot) {
        foreach ($entry in Get-ChildItem -LiteralPath $deviceClassRoot) {
            $properties = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $properties -or -not $properties.PSObject.Properties['DeviceInstance']) { continue }
            $match = $present | Where-Object InstanceId -EQ $properties.DeviceInstance | Select-Object -First 1
            if ($null -eq $match -or $match.InstanceId -match '^USB\\VID_18D1&PID_2D0[01]') { continue }
            $found.Add([pscustomobject]@{ Index = $found.Count; Name = $match.FriendlyName; State = 'ADB';
                InstanceId = $match.InstanceId; Door = ($entry.PSChildName -replace '^##\?#', '\\?\') })
        }
    }
    foreach ($accessory in $present | Where-Object InstanceId -Match '^USB\\VID_18D1&PID_2D0[01](?:&|\\)') {
        $found.Add([pscustomobject]@{ Index = $found.Count; Name = $accessory.FriendlyName; State = 'Accessory';
            InstanceId = $accessory.InstanceId; Door = '' })
    }
    $found.ToArray()
}

function Select-AoaDevice([object[]] $AvailableDevices, [string] $Selector) {
    if ([string]::IsNullOrWhiteSpace($Selector)) {
        if ($AvailableDevices.Count -ne 1) { throw "Found $($AvailableDevices.Count) devices; select one with -Device <index|instance>." }
        return $AvailableDevices[0]
    }
    $deviceIndex = 0
    if ([int]::TryParse($Selector, [ref]$deviceIndex)) {
        $selected = @($AvailableDevices | Where-Object Index -EQ $deviceIndex)
    }
    else { $selected = @($AvailableDevices | Where-Object InstanceId -EQ $Selector) }
    if ($selected.Count -ne 1) { throw 'The device selector must identify exactly one present device.' }
    $selected[0]
}

function Get-AoaLocation([string] $InstanceId) {
    # Windows' DEVPKEY_Device_LocationPaths identifies the physical USB port.
    # The AOA identity Serial describes this accessory (the PC), not the
    # phone's USB serial descriptor. Never use it to identify the returning phone.
    $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_LocationPaths -ErrorAction Stop
    foreach ($path in $property.Data) { $path -replace '#USBMI\([0-9A-F]+\)$', '' }
}

function Open-AoaBulkStream([object] $Accessory) {
    if ($Accessory.State -ne 'Accessory') { throw 'Accessory re-enumeration is required before opening its bulk pipe.' }
    $locations = @(Get-AoaLocation $Accessory.InstanceId)
    $instances = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$instances.Add($Accessory.InstanceId)
    # A composite parent and its accessory/ADB interfaces have different
    # instance IDs. Inspect their interface descriptors, not their labels.
    foreach ($candidate in Get-AoaDevice | Where-Object State -EQ Accessory) {
        $candidateLocations = @(Get-AoaLocation $candidate.InstanceId)
        if (@($candidateLocations | Where-Object { $_ -in $locations }).Count -gt 0) {
            [void]$instances.Add($candidate.InstanceId)
        }
    }
    $root = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceClasses'
    $doors = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($interfaceClass in Get-ChildItem -LiteralPath $root) {
        foreach ($entry in Get-ChildItem -LiteralPath $interfaceClass.PSPath -ErrorAction SilentlyContinue) {
            $properties = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $properties -and $properties.PSObject.Properties['DeviceInstance'] -and
                $instances.Contains($properties.DeviceInstance)) {
                [void]$doors.Add(($entry.PSChildName -replace '^##\?#', '\\?\'))
            }
        }
    }
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($door in $doors) {
        try { return [AoaBulkStream]::new($door) }
        catch { $errors.Add($_.Exception.Message) }
    }
    throw "No usable WinUSB accessory bulk interface for the selected device. Check its driver and select the accessory interface, not its ADB sibling. Attempts: $($errors -join '; ')"
}

function Invoke-AoaNegotiation([object] $ChosenDevice, [bool] $StartAccessory) {
    if ($ChosenDevice.State -eq 'Accessory') {
        return [pscustomobject]@{ Protocol = $null; StartAccepted = $false; StartError = 0;
            AccessoryObserved = $true; AlreadyAccessory = $true; Devices = @($ChosenDevice) }
    }
    $identity = @($Manufacturer, $Model, $Description, $Version, $Uri, $Serial)
    foreach ($text in $identity) {
        if ($text.IndexOf([char]0) -ge 0 -or [Text.Encoding]::UTF8.GetByteCount($text) + 1 -gt 256) {
            throw 'AOA identity strings must have no embedded NUL and at most 256 UTF-8 bytes including the terminator.'
        }
    }
    $arrival = $null
    $connection = $null
    try {
        # Register before START, then enumerate after closing the old handle.
        # This ordering retains notifications arriving during re-enumeration.
        $locations = @()
        if ($StartAccessory) {
            $locations = @(Get-AoaLocation $ChosenDevice.InstanceId)
            if ($locations.Count -eq 0) { throw 'No physical USB location is available for the selected device.' }
            $arrival = [AoaArrival]::new()
        }
        $connection = [AoaUsbHandle]::new($ChosenDevice.Door)
        $protocolReply = $connection.Control(0xc0, 51, 0, [byte[]]::new(2))
        if (-not $protocolReply.Accepted) { throw [ComponentModel.Win32Exception]::new($protocolReply.Error, 'GET_PROTOCOL failed.') }
        if ($protocolReply.Transferred -ne 2) { throw 'GET_PROTOCOL did not return two bytes.' }
        $protocol = [BitConverter]::ToUInt16($protocolReply.Data, 0)
        if ($protocol -eq 0) { throw 'The selected device reports no AOA support.' }
        if (-not $StartAccessory) {
            return [pscustomobject]@{ Protocol = $protocol; StartAccepted = $false; StartError = 0;
                AccessoryObserved = $false; AlreadyAccessory = $false; Devices = @() }
        }
        for ($identityIndex = 0; $identityIndex -lt $identity.Count; $identityIndex++) {
            $identityBytes = [Text.Encoding]::UTF8.GetBytes($identity[$identityIndex] + [char]0)
            $reply = $connection.Control(0x40, 52, [uint16]$identityIndex, $identityBytes)
            if (-not $reply.Accepted) { throw [ComponentModel.Win32Exception]::new($reply.Error, "SEND_STRING[$identityIndex] failed.") }
            if ($reply.Transferred -ne $identityBytes.Length) { throw "SEND_STRING[$identityIndex] transferred the wrong length." }
        }
        $startReply = $connection.Control(0x40, 53, 0, [byte[]]::new(0))
        $connection.Dispose(); $connection = $null
        $deadline = [Environment]::TickCount64 + $WaitMilliseconds
        do {
            $accessories = @(foreach ($candidate in Get-AoaDevice | Where-Object State -EQ Accessory) {
                $candidateLocations = @(Get-AoaLocation $candidate.InstanceId)
                if (@($candidateLocations | Where-Object { $_ -in $locations }).Count -gt 0) { $candidate }
            })
            if ($accessories.Count -gt 0) { break }
            $remaining = [int][Math]::Max(0, $deadline - [Environment]::TickCount64)
            if ($remaining -eq 0 -or -not $arrival.Signal.WaitOne($remaining)) { break }
        } while ($true)
        if ($accessories.Count -eq 0) {
            throw "Accessory re-enumeration was not observed within $WaitMilliseconds ms; START accepted=$($startReply.Accepted), Win32 error=$($startReply.Error)."
        }
        return [pscustomobject]@{ Protocol = $protocol; StartAccepted = $startReply.Accepted;
            StartError = $startReply.Error; AccessoryObserved = $true; AlreadyAccessory = $false; Devices = $accessories }
    }
    finally {
        if ($null -ne $connection) { $connection.Dispose() }
        if ($null -ne $arrival) { $arrival.Dispose() }
    }
}

if ($Command -eq 'help') {
    @'
usbaoa.ps1 devices [-Api]
usbaoa.ps1 protocol|start -Device <index|instance> [-Api]
& usbaoa.ps1 stream -Device <accessory index|instance>  # System.IO.Stream
start: optional -Manufacturer -Model -Description -Version -Uri -Serial
Close ADB connection holders first. AOA re-enumeration is a required check.
stream requires a WinUSB accessory interface and a device-side accessory reader.
'@
    return
}
if (-not $IsWindows) { throw 'This transport implementation requires Windows WinUSB.' }
$devices = @(Get-AoaDevice)
if ($Command -eq 'devices') {
    if ($Api) { $devices } else { $devices | Format-Table Index, Name, State }
    return
}
$selected = Select-AoaDevice $devices $Device
if ($Command -eq 'stream') {
    Open-AoaBulkStream $selected
    return
}
$result = Invoke-AoaNegotiation $selected ($Command -eq 'start')
if ($Api) { $result }
else { $result | Select-Object Protocol, StartAccepted, StartError, AccessoryObserved, AlreadyAccessory | Format-List }
