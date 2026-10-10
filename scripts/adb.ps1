#requires -Version 7.4
<#
.SYNOPSIS
    Pure PowerShell 7 Direct USB ADB Engine.
.DESCRIPTION
    Implements independent Android Debug Bridge (ADB) protocol over Windows WinUSB:
    - Zero adb.exe or TCP 5037 ADB server dependency.
    - Zero Add-Type, Roslyn, or C# compilation (Header-driven Dynamic P/Invoke).
    - Device discovery and explicit device selection.
    - Wire framing with 24-byte header validation, magic XOR check, and checksum verification.
    - RSA token authentication via SHA-1 SignHash (PKCS#1 v1.5).
    - Shell v2 execution with stdout, stderr, and process exit status.
    - SYNC push and pull binary round-trip with chunking and flow control.
    - NIST SP 800-122 PII redaction and SP 800-53 AC-20(3) BYOD containment.
.NOTES
    Ported into Pwsh on 2026-10-03 from the owner's ADB working folder, which is not a
    repository; source file SHA-256 8ACF898C3E575E0F2B03FB3E00F9CA0A815CA9B2E713D54776F3BF1EC44A04B2.
    Consolidated from Pwsh scripts/commands/Adb at aa4f72d. Classes and protocol
    implementation stay inline for source execution and future IL compilation.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'devices', 'shell', 'push', 'pull', 'install', 'pubkey', 'version', 'start-server', 'kill-server', 'exec-out', 'stream', 'derive-pairing-key')]
    [string] $Command = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $CommandArgs = @(),
    [Alias('s')]
    [string] $Device = '',
    [switch] $Api,
    [switch] $Foreground,
    [byte[]] $KeyMaterial
)

$ErrorActionPreference = 'Stop'

# Pairing source: C:/Dev/Adb/Spake2.cs, SHA-256
# 1B2FC8EB93684D3B8F439C75005925188206CD5694A3F6352B923D8EECEC8DEE.
# This is the existing HKDF call, not the SPAKE25519 exchange. The byte[]
# overload is directly callable in PowerShell; no C# is shipped or compiled.
class AdbPairingKey {
    static [byte[]] DeriveAesKey([byte[]] $material) {
        $info = [Text.Encoding]::UTF8.GetBytes('adb pairing_auth aes-128-gcm key')
        return [Security.Cryptography.HKDF]::DeriveKey(
            [Security.Cryptography.HashAlgorithmName]::SHA256, $material, 16, [byte[]]::new(0), $info)
    }
}

# Pending: wireless/loopback pairing and Android phone-to-phone transport,
# including the Kokoro-Hexagon consumer. Keep their implementation in this file.
# Pending consumer integration (Kokoro-Hexagon; separate repository work): pin
# the Pwsh commit providing this script, replace adb.exe calls and hard-coded
# executable paths, and rebuild its APK on the current Pwsh pin with a startup
# profile that uses the current host rather than removed Xamarin types. Keep
# that build debuggable while jobs depend on run-as. Stop the adb.exe server
# before this Windows WinUSB client takes ownership of the device.
# The next job path is a loopback listener in the app's resident runspace,
# reached through this script's device-service Stream API (tcp:<port> or
# localabstract:<name>). That replaces per-job run-as, Start.ps1 overwrites and
# force-stop. Binary job results already have exec-out; listener lifetime and
# consumer migration remain pending, not claims established by this script.
# CS2PS 70667abdf3926027a2a1c1eeffefe672ec3a09e1, 2026-10-10:
# - C:/Dev/Adb/Spake2.cs: one runtime-invocation diagnostic at the HKDF call;
#   the direct array-overload port above is independently compared with C#.
# - Spake25519Client.cs, SHA-256
#   2FBEA0DE94D4B182B04F9C34F7ACA800FE031012EF081569DDC9B77EFEA6CC56:
#   73 diagnostics (readonly fields, static initializers and further constructs).
# - AdbPairingClient.cs depends on Xamarin Java/Android bindings and surrounding
#   source. Reuse its TLS-exporter/SPAKE2/peer-info protocol through direct JNI;
#   do not ship those framework bindings. AdbConnection.cs already separates
#   wire protocol from IAdbTransport, but async/lifetime/source closure needs
#   conversion. Its source-member check retains type-initialization boundaries.
# No pair/connect or Android transport is claimed until its execution receipt.

# =============================================================================
# 1. Native WinUSB & Kernel32 P/Invoke Projection (Zero Add-Type / Zero C#)
# =============================================================================

class UsbAdbNative {
    static [Type] $_nativeType = $null

    static [Type] GetNativeType() {
        if ($null -ne [UsbAdbNative]::_nativeType) {
            return [UsbAdbNative]::_nativeType
        }

        $suffix = [Guid]::NewGuid().ToString('N')
        $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
            [Reflection.AssemblyName]::new("UsbAdb.Native.$suffix"),
            [Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $module = $assembly.DefineDynamicModule("UsbAdb.Native.$suffix")
        $type = $module.DefineType(
            "UsbAdb.Native_$suffix",
            [Reflection.TypeAttributes]'Public,Abstract,Sealed'
        )
        $flags = [Reflection.MethodAttributes]'Public,Static,PinvokeImpl'
        $cc = [Runtime.InteropServices.CallingConvention]::Winapi
        $cs = [Runtime.InteropServices.CharSet]::None

        $winusbSignatures = @(
            @('WinUsb_Initialize', [int32], @([IntPtr], [IntPtr])),
            @('WinUsb_Free', [int32], @([IntPtr])),
            @('WinUsb_QueryInterfaceSettings', [int32], @([IntPtr], [byte], [IntPtr])),
            @('WinUsb_QueryPipe', [int32], @([IntPtr], [byte], [byte], [IntPtr])),
            @('WinUsb_SetPipePolicy', [int32], @([IntPtr], [byte], [uint32], [uint32], [IntPtr])),
            @('WinUsb_ReadPipe', [int32], @([IntPtr], [byte], [IntPtr], [uint32], [IntPtr], [IntPtr])),
            @('WinUsb_WritePipe', [int32], @([IntPtr], [byte], [IntPtr], [uint32], [IntPtr], [IntPtr])),
            @('WinUsb_ResetPipe', [int32], @([IntPtr], [byte])),
            @('WinUsb_AbortPipe', [int32], @([IntPtr], [byte]))
        )

        foreach ($sig in $winusbSignatures) {
            $m = $type.DefinePInvokeMethod(
                $sig[0], 'winusb.dll', $sig[0], $flags,
                [Reflection.CallingConventions]::Standard,
                $sig[1], $sig[2], $cc, $cs
            )
            $m.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
        }

        $mLast = $type.DefinePInvokeMethod(
            'GetLastError', 'kernel32.dll', 'GetLastError', $flags,
            [Reflection.CallingConventions]::Standard,
            [uint32], [Type[]]::new(0), $cc, $cs
        )
        $mLast.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)

        [UsbAdbNative]::_nativeType = $type.CreateType()
        return [UsbAdbNative]::_nativeType
    }
}

# =============================================================================
# 2. Cryptographic Keys & Authentication Utilities
# =============================================================================

class UsbAdbCrypto {
    static [string] GetDefaultKeyPath() {
        return (Join-Path (Join-Path $env:USERPROFILE ".android") "adbkey")
    }

    static [System.Security.Cryptography.RSA] LoadOrCreateKey() {
        return [UsbAdbCrypto]::LoadOrCreateKey([UsbAdbCrypto]::GetDefaultKeyPath())
    }

    static [System.Security.Cryptography.RSA] LoadOrCreateKey([string]$path) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = [UsbAdbCrypto]::GetDefaultKeyPath()
        }

        if (Test-Path -Path $path) {
            $pem = [System.IO.File]::ReadAllText($path)
            $rsa = [System.Security.Cryptography.RSA]::Create()
            $rsa.ImportFromPem($pem)
            return $rsa
        }

        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $dir = [System.IO.Path]::GetDirectoryName($path)
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($path, $rsa.ExportPkcs8PrivateKeyPem())
        $pub = [UsbAdbCrypto]::EncodeAdbPublicKey($rsa, "$env:USERNAME@$env:COMPUTERNAME")
        [System.IO.File]::WriteAllText("$path.pub", $pub)
        return $rsa
    }

    static [string] GetPublicKeyString() {
        $pubPath = "$([UsbAdbCrypto]::GetDefaultKeyPath()).pub"
        if (Test-Path $pubPath) {
            $existing = ([System.IO.File]::ReadAllText($pubPath)).Trim()
            if ($existing.Length -gt 0) { return $existing }
        }
        $rsa = [UsbAdbCrypto]::LoadOrCreateKey()
        return [UsbAdbCrypto]::EncodeAdbPublicKey($rsa, "$env:USERNAME@$env:COMPUTERNAME")
    }

    static [string] EncodeAdbPublicKey([System.Security.Cryptography.RSA]$rsa, [string]$name) {
        $params = $rsa.ExportParameters($false)
        $nBytes = $params.Modulus
        [Array]::Reverse($nBytes)
        $nExt = [byte[]]::new($nBytes.Length + 1)
        [Buffer]::BlockCopy($nBytes, 0, $nExt, 0, $nBytes.Length)
        $n = [System.Numerics.BigInteger]::new($nExt)

        $r32 = [System.Numerics.BigInteger]::One -shl 32
        $r = [System.Numerics.BigInteger]::One -shl 2048
        $rr = ($r * $r) % $n

        $n0invBig = [UsbAdbCrypto]::ModInverse($n % $r32, $r32)
        $n0inv = [uint32]([int64]($r32 - $n0invBig) % [int64]$r32)

        $buf = [byte[]]::new(524)
        $off = [ref]0
        [UsbAdbCrypto]::WriteU32($buf, $off, 64)
        [UsbAdbCrypto]::WriteU32($buf, $off, $n0inv)
        [UsbAdbCrypto]::WriteLe($buf, $off, $n, 256)
        [UsbAdbCrypto]::WriteLe($buf, $off, $rr, 256)

        $e = 0
        foreach ($b in $params.Exponent) {
            $e = ($e -shl 8) -bor [int]$b
        }
        [UsbAdbCrypto]::WriteU32($buf, $off, [uint32]$e)

        return "$([Convert]::ToBase64String($buf)) $name"
    }

    static [void] WriteU32([byte[]]$buf, [ref]$off, [uint32]$v) {
        [Buffer]::BlockCopy([BitConverter]::GetBytes($v), 0, $buf, $off.Value, 4)
        $off.Value += 4
    }

    static [void] WriteLe([byte[]]$buf, [ref]$off, [System.Numerics.BigInteger]$v, [int]$len) {
        $bytes = $v.ToByteArray()
        [Buffer]::BlockCopy($bytes, 0, $buf, $off.Value, [Math]::Min($bytes.Length, $len))
        $off.Value += $len
    }

    static [System.Numerics.BigInteger] ModInverse([System.Numerics.BigInteger]$a, [System.Numerics.BigInteger]$m) {
        return [System.Numerics.BigInteger]::ModPow($a, $m - 2, $m)
    }

    static [string] RedactSerial([string]$input) {
        if ([string]::IsNullOrWhiteSpace($input)) { return $input }
        # Redact USB instance serial portion: USB\VID_xxxx&PID_xxxx\<serial>
        $out = $input -replace '(?<=VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}\\)[^\\&]+', '[DEVICE_SERIAL_REDACTED]'
        $out = $out -replace '(?<=VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}#)[^#]+', '[DEVICE_SERIAL_REDACTED]'
        # Redact ADB system identity serial: device:<serial>:banner
        $out = $out -replace '^(device|host|bootloader):[^:]+:(.*)$', '$1:[DEVICE_SERIAL_REDACTED]:$2'
        return $out
    }
}

# =============================================================================
# 3. Device Discovery & Representation
# =============================================================================

class UsbAdbDeviceInfo {
    [int]$Index
    [string]$FriendlyName
    [string]$InstanceId
    [string]$RedactedInstanceId
    [string]$Door
    [bool]$IsAccessible
    [string]$AccessError
    [string]$OwningProcessNotice

    UsbAdbDeviceInfo([int]$deviceIndex, [string]$name, [string]$inst, [string]$deviceDoor) {
        $this.Index = $deviceIndex
        $this.FriendlyName = $name
        $this.InstanceId = $inst
        $this.RedactedInstanceId = [UsbAdbCrypto]::RedactSerial($inst)
        $this.Door = $deviceDoor
        $this.IsAccessible = $true
        $this.AccessError = $null
        $this.OwningProcessNotice = $null
    }

    [void] CheckAccessibility() {
        try {
            $h = [System.IO.File]::OpenHandle(
                $this.Door,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::ReadWrite,
                [System.IO.FileOptions]::Asynchronous
            )
            $this.IsAccessible = $true
            $this.AccessError = $null
            $this.OwningProcessNotice = $null
            $h.Dispose()
        } catch [System.UnauthorizedAccessException] {
            $this.IsAccessible = $false
            $this.AccessError = "Access Denied (0x80070005: ERROR_ACCESS_DENIED)"
            $adbProc = @(Get-Process -Name 'adb' -ErrorAction SilentlyContinue)
            if ($adbProc.Count -gt 0) {
                $pids = ($adbProc | ForEach-Object { $_.Id }) -join ', '
                $this.OwningProcessNotice = "USB interface is owned by running adb.exe process (PID: $pids)."
            } else {
                $this.OwningProcessNotice = "USB interface handle is opened exclusively by another process."
            }
        } catch [System.Exception] {
            $this.IsAccessible = $false
            $this.AccessError = $_.Message
            $this.OwningProcessNotice = $null
        }
    }
}

function Get-UsbAdbDevices {
    [CmdletBinding()]
    param([switch]$CheckAccess)

    $guid = '{F72FE0D4-CBCB-407D-8814-9ED673D0DD6B}'
    $deviceClassRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"

    if (-not (Test-Path -LiteralPath $deviceClassRoot)) {
        return @()
    }

    $pnp = @(Get-PnpDevice -Class 'AndroidUsbDeviceClass' -PresentOnly -ErrorAction SilentlyContinue)
    $devices = [System.Collections.Generic.List[UsbAdbDeviceInfo]]::new()
    $idx = 0

    foreach ($key in Get-ChildItem -LiteralPath $deviceClassRoot -ErrorAction SilentlyContinue) {
        $property = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace($property.DeviceInstance)) {
            continue
        }

        $inst = $property.DeviceInstance
        $matched = $pnp | Where-Object { $_.InstanceId -ieq $inst } | Select-Object -First 1
        if (-not $matched) {
            continue
        }

        $name = if ($matched.FriendlyName) { $matched.FriendlyName } else { "Android ADB Device" }
        $door = $key.PSChildName -replace '^##\?#', '\\?\'

        $info = [UsbAdbDeviceInfo]::new($idx, $name, $inst, $door)
        if ($CheckAccess) {
            $info.CheckAccessibility()
        }
        $devices.Add($info)
        $idx++
    }

    return $devices.ToArray()
}

# =============================================================================
# 4. ADB Wire Message & Client Implementation
# =============================================================================

class UsbAdbWireMessage {
    [uint32]$Command
    [uint32]$Arg0
    [uint32]$Arg1
    [uint32]$DataLength
    [uint32]$DataCrc32
    [uint32]$Magic
    [byte[]]$Data = [Array]::Empty[byte]()

    static [uint32] CalculateChecksum([byte[]]$bytes) {
        if ($null -eq $bytes -or $bytes.Length -eq 0) { return 0 }
        $sum = 0
        foreach ($b in $bytes) {
            $sum = ($sum + [int]$b) -band 0xFFFFFFFF
        }
        return [uint32]$sum
    }
}

class UsbAdbClient : IDisposable {
    # Protocol Constants (aosp-adb/adb.h lines 42-58)
    static [uint32]$A_SYNC = 0x434e5953
    static [uint32]$A_CNXN = 0x4e584e43
    static [uint32]$A_OPEN = 0x4e45504f
    static [uint32]$A_OKAY = 0x59414b4f
    static [uint32]$A_CLSE = 0x45534c43
    static [uint32]$A_WRTE = 0x45545257
    static [uint32]$A_AUTH = 0x48545541

    # Protocol Versions (aosp-adb/adb.h lines 56-58)
    static [uint32]$A_VERSION_MIN = 0x01000000
    static [uint32]$A_VERSION_SKIP_CHECKSUM = 0x01000001
    static [uint32]$A_VERSION = 0x01000001

    # Auth Constants (aosp-adb/adb_auth.h lines 29-32)
    static [uint32]$ADB_AUTH_TOKEN = 1
    static [uint32]$ADB_AUTH_SIGNATURE = 2
    static [uint32]$ADB_AUTH_RSAPUBLICKEY = 3

    # Sync Constants (aosp-adb/file_sync_protocol.h lines 23-40)
    static [uint32]$ID_SEND_V1 = 0x444e4553  # 'SEND'
    static [uint32]$ID_RECV_V1 = 0x56434552  # 'RECV'
    static [uint32]$ID_DATA    = 0x41544144  # 'DATA'
    static [uint32]$ID_DONE    = 0x454e4f44  # 'DONE'
    static [uint32]$ID_OKAY    = 0x59414b4f  # 'OKAY'
    static [uint32]$ID_FAIL    = 0x4c494146  # 'FAIL'
    static [uint32]$ID_QUIT    = 0x54495551  # 'QUIT'

    static [uint32]$MAX_PAYLOAD = 1048576    # 1MB
    static [int]$SYNC_DATA_MAX  = 65536      # 64KB

    [UsbAdbDeviceInfo]$Device
    [System.Security.Cryptography.RSA]$_rsa
    [Type]$_native
    [Microsoft.Win32.SafeHandles.SafeFileHandle]$_devHandle
    [IntPtr]$_usbHandle = [IntPtr]::Zero
    [Runtime.InteropServices.GCHandle]$_usbPin

    [byte]$_pipeIn = 0
    [byte]$_pipeOut = 0
    [uint16]$_maxPacketIn = 512
    [uint16]$_maxPacketOut = 512
    [uint32]$_protocolVersion = [UsbAdbClient]::A_VERSION_MIN
    [uint32]$_maxPayload = [UsbAdbClient]::MAX_PAYLOAD
    [string]$_deviceBanner = ""
    [hashtable]$_deviceProperties = @{}

    # Sync state
    [System.Collections.Generic.List[byte]]$_syncRecvBuffer = [System.Collections.Generic.List[byte]]::new()
    [bool]$_syncCanWrite = $true

    # Stream routing (aosp-adb 1cf2f017 docs/dev/protocol.md): stream IDs are
    # unique per connection and relative to the sender, so a received OKAY,
    # WRTE or CLSE belongs to the local stream named in arg1. Messages for
    # another open stream wait in its queue; messages for a stream that is not
    # open are ignored, since it may have closed while they were in flight.
    [uint32]$_nextLocalId = 1
    [System.Collections.Generic.HashSet[uint32]]$_openStreams = [System.Collections.Generic.HashSet[uint32]]::new()
    [hashtable]$_pending = @{}

    UsbAdbClient([UsbAdbDeviceInfo]$selectedDevice) {
        $this.Init($selectedDevice, [UsbAdbCrypto]::LoadOrCreateKey())
    }

    UsbAdbClient([UsbAdbDeviceInfo]$selectedDevice, [System.Security.Cryptography.RSA]$rsa) {
        $this.Init($selectedDevice, $rsa)
    }

    [void] Init([UsbAdbDeviceInfo]$selectedDevice, [System.Security.Cryptography.RSA]$rsa) {
        $this.Device = $selectedDevice
        $this._rsa = $rsa
        $this._native = [UsbAdbNative]::GetNativeType()

        [IntPtr[]]$usbOut = [IntPtr[]]::new(1)
        $this._usbPin = [Runtime.InteropServices.GCHandle]::Alloc($usbOut, [Runtime.InteropServices.GCHandleType]::Pinned)

        # Open handle and initialize WinUSB with retry for rapid successive CLI invocations
        $attempts = 0
        while ($attempts -lt 10) {
            try {
                $this._devHandle = [System.IO.File]::OpenHandle(
                    $selectedDevice.Door,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::ReadWrite,
                    [System.IO.FileOptions]::Asynchronous
                )

                $ok = $this._native::WinUsb_Initialize($this._devHandle.DangerousGetHandle(), $this._usbPin.AddrOfPinnedObject())
                if ($ok -ne 0) {
                    $this._usbHandle = $usbOut[0]
                    break
                }

                $err = $this._native::GetLastError()
                $this._devHandle.Dispose()
                $this._devHandle = $null

                $attempts++
                if ($attempts -lt 10) {
                    [System.Threading.Thread]::Sleep(200)
                    continue
                }
                throw [System.ComponentModel.Win32Exception]::new([int]$err)
            } catch [System.UnauthorizedAccessException] {
                $adbProc = @(Get-Process -Name 'adb' -ErrorAction SilentlyContinue)
                $notice = if ($adbProc.Count -gt 0) {
                    "USB interface is owned by running adb.exe (PID: $(($adbProc | ForEach-Object { $_.Id }) -join ', '))."
                } else {
                    "USB interface is locked exclusively by another process."
                }
                throw [System.InvalidOperationException]::new("Access denied to device '$($selectedDevice.FriendlyName)' [$($selectedDevice.RedactedInstanceId)]. $notice")
            } catch {
                if ($null -ne $this._devHandle) {
                    $this._devHandle.Dispose()
                    $this._devHandle = $null
                }
                $attempts++
                if ($attempts -ge 10) {
                    throw [System.InvalidOperationException]::new("Failed to open device handle for '$($selectedDevice.FriendlyName)' [$($selectedDevice.RedactedInstanceId)]: $($_.Message)")
                }
                [System.Threading.Thread]::Sleep(200)
            }
        }

        if ($this._usbHandle -eq [IntPtr]::Zero) {
            throw [System.InvalidOperationException]::new("WinUsb_Initialize failed after retries for device '$($selectedDevice.FriendlyName)'.")
        }

        # Query pipes and endpoint descriptors
        $desc = [byte[]]::new(9)
        $descPin = [Runtime.InteropServices.GCHandle]::Alloc($desc, [Runtime.InteropServices.GCHandleType]::Pinned)
        try {
            $this._native::WinUsb_QueryInterfaceSettings($this._usbHandle, 0, $descPin.AddrOfPinnedObject()) | Out-Null
        } finally {
            $descPin.Free()
        }

        $numEndpoints = $desc[4]
        for ([byte]$i = 0; $i -lt $numEndpoints; $i++) {
            $pipe = [byte[]]::new(12)
            $pipePin = [Runtime.InteropServices.GCHandle]::Alloc($pipe, [Runtime.InteropServices.GCHandleType]::Pinned)
            try {
                $this._native::WinUsb_QueryPipe($this._usbHandle, 0, $i, $pipePin.AddrOfPinnedObject()) | Out-Null
                $pType = [BitConverter]::ToInt32($pipe, 0)
                $ep = $pipe[4]
                $maxPkt = [BitConverter]::ToUInt16($pipe, 6)
                if ($pType -eq 2) { # Bulk transfer
                    if (($ep -band 0x80) -ne 0) {
                        $this._pipeIn = $ep
                        $this._maxPacketIn = $maxPkt
                    } else {
                        $this._pipeOut = $ep
                        $this._maxPacketOut = $maxPkt
                    }
                }
            } finally {
                $pipePin.Free()
            }
        }

        if ($this._pipeIn -eq 0 -or $this._pipeOut -eq 0) {
            throw "Bulk endpoint discovery failed: IN=0x$($this._pipeIn.ToString('X2')) OUT=0x$($this._pipeOut.ToString('X2'))"
        }


        # Set pipe policies: PIPE_TRANSFER_TIMEOUT = 5000ms, SHORT_PACKET_TERMINATE = 1
        [uint32[]]$timeout = @([uint32]10000)
        $timeoutPin = [Runtime.InteropServices.GCHandle]::Alloc($timeout, [Runtime.InteropServices.GCHandleType]::Pinned)
        try {
            $this._native::WinUsb_SetPipePolicy($this._usbHandle, $this._pipeIn, 3, 4, $timeoutPin.AddrOfPinnedObject()) | Out-Null
            $this._native::WinUsb_SetPipePolicy($this._usbHandle, $this._pipeOut, 3, 4, $timeoutPin.AddrOfPinnedObject()) | Out-Null
        } finally {
            $timeoutPin.Free()
        }

        [byte[]]$spt = @([byte]1)
        $sptPin = [Runtime.InteropServices.GCHandle]::Alloc($spt, [Runtime.InteropServices.GCHandleType]::Pinned)
        try {
            $this._native::WinUsb_SetPipePolicy($this._usbHandle, $this._pipeOut, 1, 1, $sptPin.AddrOfPinnedObject()) | Out-Null
        } finally {
            $sptPin.Free()
        }

        # Start each session with both bulk endpoints in a known state. ResetPipe
        # issues CLEAR_FEATURE(ENDPOINT_HALT), which clears a stall and resets the
        # data toggle on host and device (USB 2.0 section 9.4.5). Without it a new
        # session can start out of toggle step with the device, which then drops
        # the first packet as a duplicate and reads later bytes as a header.
        foreach ($pipe in @($this._pipeIn, $this._pipeOut)) {
            if ($this._native::WinUsb_ResetPipe($this._usbHandle, $pipe) -eq 0) {
                throw [System.ComponentModel.Win32Exception]::new([int]$this._native::GetLastError())
            }
        }
    }

    [void] SendWireMessage([uint32]$cmd, [uint32]$arg0, [uint32]$arg1, [byte[]]$data) {
        if ($null -eq $data) { $data = [Array]::Empty[byte]() }
        if ($data.Length -gt [UsbAdbClient]::MAX_PAYLOAD) {
            throw "Wire message payload $($data.Length) exceeds MAX_PAYLOAD ($([UsbAdbClient]::MAX_PAYLOAD))"
        }

        $header = [byte[]]::new(24)
        [Buffer]::BlockCopy([BitConverter]::GetBytes($cmd), 0, $header, 0, 4)
        [Buffer]::BlockCopy([BitConverter]::GetBytes($arg0), 0, $header, 4, 4)
        [Buffer]::BlockCopy([BitConverter]::GetBytes($arg1), 0, $header, 8, 4)
        [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$data.Length), 0, $header, 12, 4)

        $sum = [UsbAdbWireMessage]::CalculateChecksum($data)
        [Buffer]::BlockCopy([BitConverter]::GetBytes($sum), 0, $header, 16, 4)
        [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]($cmd -bxor 0xFFFFFFFF)), 0, $header, 20, 4)

        # Write header
        [uint32[]]$written = [uint32[]]::new(1)
        $hPin = [Runtime.InteropServices.GCHandle]::Alloc($header, [Runtime.InteropServices.GCHandleType]::Pinned)
        $wPin = [Runtime.InteropServices.GCHandle]::Alloc($written, [Runtime.InteropServices.GCHandleType]::Pinned)
        try {
            $ok = $this._native::WinUsb_WritePipe($this._usbHandle, $this._pipeOut, $hPin.AddrOfPinnedObject(), 24, $wPin.AddrOfPinnedObject(), [IntPtr]::Zero)
            if ($ok -eq 0) {
                $err = $this._native::GetLastError()
                throw [System.ComponentModel.Win32Exception]::new([int]$err)
            }
        } finally {
            $wPin.Free()
            $hPin.Free()
        }

        # Write payload
        if ($data.Length -gt 0) {
            $dPin = [Runtime.InteropServices.GCHandle]::Alloc($data, [Runtime.InteropServices.GCHandleType]::Pinned)
            $wPin = [Runtime.InteropServices.GCHandle]::Alloc($written, [Runtime.InteropServices.GCHandleType]::Pinned)
            try {
                $ok = $this._native::WinUsb_WritePipe($this._usbHandle, $this._pipeOut, $dPin.AddrOfPinnedObject(), [uint32]$data.Length, $wPin.AddrOfPinnedObject(), [IntPtr]::Zero)
                if ($ok -eq 0) {
                    $err = $this._native::GetLastError()
                    throw [System.ComponentModel.Win32Exception]::new([int]$err)
                }
            } finally {
                $wPin.Free()
                $dPin.Free()
            }
        }
    }

    [UsbAdbWireMessage] ReadWireMessage() {
        # Read header: buffer sized to multiple of maxPacketIn to avoid USB overflow (aosp-adb/client/transport_usb.cpp lines 42-61)
        $bufSize = [Math]::Max([int]$this._maxPacketIn, 512)
        $headerBuf = [byte[]]::new($bufSize)
        [uint32[]]$bytesRead = [uint32[]]::new(1)

        $hPin = [Runtime.InteropServices.GCHandle]::Alloc($headerBuf, [Runtime.InteropServices.GCHandleType]::Pinned)
        $rPin = [Runtime.InteropServices.GCHandle]::Alloc($bytesRead, [Runtime.InteropServices.GCHandleType]::Pinned)
        try {
            $ok = $this._native::WinUsb_ReadPipe($this._usbHandle, $this._pipeIn, $hPin.AddrOfPinnedObject(), [uint32]$bufSize, $rPin.AddrOfPinnedObject(), [IntPtr]::Zero)
            if ($ok -eq 0) {
                $err = $this._native::GetLastError()
                throw [System.ComponentModel.Win32Exception]::new([int]$err)
            }
        } finally {
            $rPin.Free()
            $hPin.Free()
        }

        if ($bytesRead[0] -lt 24) {
            throw "ReadWireMessage: Short read on header ($($bytesRead[0]) bytes; expected 24)."
        }

        $cmd = [BitConverter]::ToUInt32($headerBuf, 0)
        $arg0 = [BitConverter]::ToUInt32($headerBuf, 4)
        $arg1 = [BitConverter]::ToUInt32($headerBuf, 8)
        $dLen = [BitConverter]::ToUInt32($headerBuf, 12)
        $dCrc = [BitConverter]::ToUInt32($headerBuf, 16)
        $magic = [BitConverter]::ToUInt32($headerBuf, 20)

        # Bounded wire framing verification (aosp-adb/docs/dev/protocol.md lines 37-43)
        $expectedMagic = [uint32]($cmd -bxor 0xFFFFFFFF)
        if ($magic -ne $expectedMagic) {
            throw "Corrupted wire header magic: cmd=0x$($cmd.ToString('X8')), magic=0x$($magic.ToString('X8')), expected=0x$($expectedMagic.ToString('X8'))"
        }
        if ($dLen -gt [UsbAdbClient]::MAX_PAYLOAD) {
            throw "Received message payload length $dLen exceeds MAX_PAYLOAD ($([UsbAdbClient]::MAX_PAYLOAD))."
        }

        $payload = [Array]::Empty[byte]()
        if ($dLen -gt 0) {
            # Round up read buffer to maxPacketIn boundary per aosp-adb/client/transport_usb.cpp line 78
            $rem = $dLen % [uint32]$this._maxPacketIn
            $allocLen = if ($rem -ne 0) { $dLen + ([uint32]$this._maxPacketIn - $rem) } else { $dLen }
            $readBuf = [byte[]]::new($allocLen)

            $total = 0
            while ($total -lt $dLen) {
                $chunkSize = [uint32]($allocLen - $total)
                $chunk = [byte[]]::new($chunkSize)
                $cPin = [Runtime.InteropServices.GCHandle]::Alloc($chunk, [Runtime.InteropServices.GCHandleType]::Pinned)
                $rPin = [Runtime.InteropServices.GCHandle]::Alloc($bytesRead, [Runtime.InteropServices.GCHandleType]::Pinned)
                try {
                    $ok = $this._native::WinUsb_ReadPipe($this._usbHandle, $this._pipeIn, $cPin.AddrOfPinnedObject(), $chunkSize, $rPin.AddrOfPinnedObject(), [IntPtr]::Zero)
                    if ($ok -eq 0) {
                        $err = $this._native::GetLastError()
                        throw [System.ComponentModel.Win32Exception]::new([int]$err)
                    }
                } finally {
                    $rPin.Free()
                    $cPin.Free()
                }

                if ($bytesRead[0] -eq 0) {
                    throw "ReadPipe returned 0 bytes during payload read."
                }
                [Buffer]::BlockCopy($chunk, 0, $readBuf, $total, [int]$bytesRead[0])
                $total += [int]$bytesRead[0]
            }

            $payload = [byte[]]::new($dLen)
            [Buffer]::BlockCopy($readBuf, 0, $payload, 0, [int]$dLen)

            # Checksum verification (for CNXN/AUTH or protocol < SKIP_CHECKSUM).
            # A zero checksum means the sender did not compute one: adbd writes 0
            # once its transport's protocol version reaches SKIP_CHECKSUM, which can
            # persist from an earlier host session (aosp-adb 1cf2f017 transport.cpp
            # send_packet, lines 565-570). Upstream does not verify on receive.
            if ($dCrc -ne 0 -and ($cmd -eq [UsbAdbClient]::A_CNXN -or $cmd -eq [UsbAdbClient]::A_AUTH -or $this._protocolVersion -lt [UsbAdbClient]::A_VERSION_SKIP_CHECKSUM)) {
                $calcCrc = [UsbAdbWireMessage]::CalculateChecksum($payload)
                if ($calcCrc -ne $dCrc) {
                    throw "Payload checksum mismatch: header=0x$($dCrc.ToString('X8')), computed=0x$($calcCrc.ToString('X8'))"
                }
            }
        }

        $msg = [UsbAdbWireMessage]::new()
        $msg.Command = $cmd
        $msg.Arg0 = $arg0
        $msg.Arg1 = $arg1
        $msg.DataLength = $dLen
        $msg.DataCrc32 = $dCrc
        $msg.Magic = $magic
        $msg.Data = $payload
        return $msg
    }

    [void] Connect() {
        # aosp-adb/client/transport.cpp & protocol.md: Send CNXN
        $features = "host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,fixed_push_symlink_timestamp,abb_exec,remount,sendrecv_v2"
        $featBytes = [System.Text.Encoding]::ASCII.GetBytes($features)
        $this.SendWireMessage([UsbAdbClient]::A_CNXN, [UsbAdbClient]::A_VERSION, [UsbAdbClient]::MAX_PAYLOAD, $featBytes)

        # Read response, ignoring stale packets prior to CONNECT per protocol.md line 72
        $resp = $null
        while ($true) {
            $resp = $this.ReadWireMessage()
            if ($resp.Command -eq [UsbAdbClient]::A_AUTH -or $resp.Command -eq [UsbAdbClient]::A_CNXN) {
                break
            }
        }

        # Handle AUTH negotiation (aosp-adb/client/auth.cpp lines 456-481)
        if ($resp.Command -eq [UsbAdbClient]::A_AUTH) {
            $token = $resp.Data
            # OpenSSL RSA_sign over token digest -> .NET SignHash (SHA-1 PKCS#1 v1.5)
            $sig = $this._rsa.SignHash($token, [System.Security.Cryptography.HashAlgorithmName]::SHA1, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $this.SendWireMessage([UsbAdbClient]::A_AUTH, [UsbAdbClient]::ADB_AUTH_SIGNATURE, 0, $sig)

            $authResp = $null
            while ($true) {
                $authResp = $this.ReadWireMessage()
                if ($authResp.Command -eq [UsbAdbClient]::A_AUTH -or $authResp.Command -eq [UsbAdbClient]::A_CNXN) {
                    break
                }
            }

            if ($authResp.Command -eq [UsbAdbClient]::A_AUTH) {
                # Signature rejected, send public key with null terminator
                $pubKey = [UsbAdbCrypto]::GetPublicKeyString()
                $pubBytes = [System.Text.Encoding]::ASCII.GetBytes("$pubKey`0")
                $this.SendWireMessage([UsbAdbClient]::A_AUTH, [UsbAdbClient]::ADB_AUTH_RSAPUBLICKEY, 0, $pubBytes)
                while ($true) {
                    $authResp = $this.ReadWireMessage()
                    if ($authResp.Command -eq [UsbAdbClient]::A_CNXN) {
                        break
                    }
                }
            }

            if ($authResp.Command -ne [UsbAdbClient]::A_CNXN) {
                throw "ADB Authentication rejected: cmd=0x$($authResp.Command.ToString('X8'))"
            }
            $resp = $authResp
        }

        if ($resp.Command -ne [UsbAdbClient]::A_CNXN) {
            throw "Unexpected response to CNXN: cmd=0x$($resp.Command.ToString('X8'))"
        }

        $this._protocolVersion = $resp.Arg0
        $this._maxPayload = $resp.Arg1
        $this._deviceBanner = [System.Text.Encoding]::UTF8.GetString($resp.Data)

        # Parse device banner properties (e.g. ro.product.model, ro.product.name)
        $this.ParseBanner($this._deviceBanner)
    }

    [void] ParseBanner([string]$raw) {
        $this._deviceProperties.Clear()
        $parts = $raw -split ':', 3
        if ($parts.Length -ge 3) {
            $banner = $parts[2]
            foreach ($prop in $banner -split ';') {
                $kv = $prop -split '=', 2
                if ($kv.Length -eq 2) {
                    $this._deviceProperties[$kv[0]] = $kv[1]
                }
            }
        }
    }

    [hashtable] GetDeviceProperties() {
        return $this._deviceProperties
    }

    [string] GetDeviceBannerRedacted() {
        return [UsbAdbCrypto]::RedactSerial($this._deviceBanner)
    }

    # =========================================================================
    # Shell v2 Execution (aosp-adb/shell_protocol.h & daemon/services.cpp)
    # =========================================================================

    [uint32] OpenStream([string]$destination) {
        $localId = $this._nextLocalId
        $this._nextLocalId = if ($localId -eq [uint32]::MaxValue) { [uint32]1 } else { $localId + 1 }
        [void]$this._openStreams.Add($localId)
        $this.SendWireMessage([UsbAdbClient]::A_OPEN, $localId, 0, [System.Text.Encoding]::UTF8.GetBytes("$destination`0"))
        return $localId
    }

    [UsbAdbWireMessage] ReadStreamMessage([uint32]$localId) {
        $queue = $this._pending[$localId]
        if ($null -ne $queue -and $queue.Count -gt 0) { return $queue.Dequeue() }
        while ($true) {
            $m = $this.ReadWireMessage()
            if ($m.Command -eq [UsbAdbClient]::A_OKAY -or $m.Command -eq [UsbAdbClient]::A_WRTE -or $m.Command -eq [UsbAdbClient]::A_CLSE) {
                if ($m.Arg1 -eq $localId) { return $m }
                if ($this._openStreams.Contains($m.Arg1)) {
                    if (-not $this._pending.ContainsKey($m.Arg1)) { $this._pending[$m.Arg1] = [System.Collections.Generic.Queue[object]]::new() }
                    $this._pending[$m.Arg1].Enqueue($m)
                }
                continue
            }
            if ($m.Command -eq [UsbAdbClient]::A_CNXN -or $m.Command -eq [UsbAdbClient]::A_AUTH) {
                throw "The device restarted the connection (cmd=0x$($m.Command.ToString('X8'))) while stream $localId was open."
            }
        }
        return $null
    }

    [void] CloseStream([uint32]$localId, [uint32]$remoteId) {
        if ($this._openStreams.Remove($localId) -and $remoteId -ne 0) {
            $this.SendWireMessage([UsbAdbClient]::A_CLSE, $localId, $remoteId, $null)
        }
        $this._pending.Remove($localId)
    }

    [PSCustomObject] ExecuteShell([string]$command) {
        $localId = $this.OpenStream("shell,v2,raw:$command")
        $remoteId = [uint32]0
        $stdoutBuilder = [System.Text.StringBuilder]::new()
        $stderrBuilder = [System.Text.StringBuilder]::new()
        $exitCode = -1

        try {
        while ($true) {
            $msg = $this.ReadStreamMessage($localId)

            if ($msg.Command -eq [UsbAdbClient]::A_OKAY) {
                $remoteId = $msg.Arg0
            } elseif ($msg.Command -eq [UsbAdbClient]::A_WRTE) {
                # Immediate flow control ACK
                $this.SendWireMessage([UsbAdbClient]::A_OKAY, $localId, $remoteId, $null)

                # Decode ShellProtocol packets (1-byte ID + 4-byte LE length + payload)
                $off = 0
                while ($off + 5 -le $msg.Data.Length) {
                    $id = $msg.Data[$off]
                    $len = [BitConverter]::ToUInt32($msg.Data, $off + 1)
                    $chunk = [byte[]]::new($len)
                    [Buffer]::BlockCopy($msg.Data, $off + 5, $chunk, 0, [int]$len)
                    $off += 5 + [int]$len

                    switch ($id) {
                        1 { # kIdStdout
                            $stdoutBuilder.Append([System.Text.Encoding]::UTF8.GetString($chunk)) | Out-Null
                        }
                        2 { # kIdStderr
                            $stderrBuilder.Append([System.Text.Encoding]::UTF8.GetString($chunk)) | Out-Null
                        }
                        3 { # kIdExit
                            $exitCode = [int]$chunk[0]
                        }
                    }
                }
            } elseif ($msg.Command -eq [UsbAdbClient]::A_CLSE) {
                if ($remoteId -eq 0) { $remoteId = $msg.Arg0 }
                break
            }
        }
        }
        finally { $this.CloseStream($localId, $remoteId) }

        return [PSCustomObject]@{
            ExitCode = $exitCode
            Stdout   = $stdoutBuilder.ToString()
            Stderr   = $stderrBuilder.ToString()
        }
    }

    # =========================================================================
    # SYNC Push / Pull Implementation (aosp-adb/file_sync_protocol.h)
    # =========================================================================

    [void] SendSyncWirePacket([uint32]$syncLocalId, [uint32]$syncRemoteId, [byte[]]$bytes) {
        if (-not $this._syncCanWrite) {
            while (-not $this._syncCanWrite) {
                $m = $this.ReadStreamMessage($syncLocalId)
                if ($m.Command -eq [UsbAdbClient]::A_OKAY) {
                    $this._syncCanWrite = $true
                } elseif ($m.Command -eq [UsbAdbClient]::A_WRTE) {
                    $this.SendWireMessage([UsbAdbClient]::A_OKAY, $syncLocalId, $syncRemoteId, $null)
                    if ($m.Data.Length -gt 0) { [void]$this._syncRecvBuffer.AddRange($m.Data) }
                } elseif ($m.Command -eq [UsbAdbClient]::A_CLSE) {
                    throw "Sync stream closed unexpectedly by remote while awaiting OKAY."
                }
            }
        }

        $this.SendWireMessage([UsbAdbClient]::A_WRTE, $syncLocalId, $syncRemoteId, $bytes)
        $this._syncCanWrite = $false

        # Await OKAY acknowledging our write
        while (-not $this._syncCanWrite) {
            $m = $this.ReadStreamMessage($syncLocalId)
            if ($m.Command -eq [UsbAdbClient]::A_OKAY) {
                $this._syncCanWrite = $true
            } elseif ($m.Command -eq [UsbAdbClient]::A_WRTE) {
                $this.SendWireMessage([UsbAdbClient]::A_OKAY, $syncLocalId, $syncRemoteId, $null)
                if ($m.Data.Length -gt 0) { [void]$this._syncRecvBuffer.AddRange($m.Data) }
            } elseif ($m.Command -eq [UsbAdbClient]::A_CLSE) {
                throw "Sync stream closed unexpectedly by remote."
            }
        }
    }

    [byte[]] ReadSyncStreamBytes([uint32]$syncLocalId, [uint32]$syncRemoteId, [int]$count) {
        while ($this._syncRecvBuffer.Count -lt $count) {
            $m = $this.ReadStreamMessage($syncLocalId)
            if ($m.Command -eq [UsbAdbClient]::A_WRTE) {
                $this.SendWireMessage([UsbAdbClient]::A_OKAY, $syncLocalId, $syncRemoteId, $null)
                if ($m.Data.Length -gt 0) { [void]$this._syncRecvBuffer.AddRange($m.Data) }
            } elseif ($m.Command -eq [UsbAdbClient]::A_OKAY) {
                $this._syncCanWrite = $true
            } elseif ($m.Command -eq [UsbAdbClient]::A_CLSE) {
                throw "Sync stream closed unexpectedly by remote while reading data."
            }
        }

        $res = $this._syncRecvBuffer.GetRange(0, $count).ToArray()
        $this._syncRecvBuffer.RemoveRange(0, $count)
        return $res
    }

    [void] PushFile([string]$localPath, [string]$remotePath) {
        $this.PushFile($localPath, $remotePath, [uint32]33188)
    }

    [void] PushFile([string]$localPath, [string]$remotePath, [uint32]$mode) {
        if (-not (Test-Path -LiteralPath $localPath)) {
            throw "Local file does not exist: $localPath"
        }
        $fileBytes = [System.IO.File]::ReadAllBytes($localPath)
        $this.PushBytes($fileBytes, $remotePath, $mode)
    }

    [void] PushBytes([byte[]]$fileBytes, [string]$remotePath) {
        $this.PushBytes($fileBytes, $remotePath, [uint32]33188)
    }

    [void] PushBytes([byte[]]$fileBytes, [string]$remotePath, [uint32]$mode) {
        $this._syncRecvBuffer.Clear()
        $this._syncCanWrite = $true

        $syncLocalId = $this.OpenStream('sync:')
        $syncRemoteId = [uint32]0
        $resp = $this.ReadStreamMessage($syncLocalId)
        if ($resp.Command -ne [UsbAdbClient]::A_OKAY) {
            $this.CloseStream($syncLocalId, $resp.Arg0)
            throw "Failed to open sync stream: cmd=0x$($resp.Command.ToString('X8'))"
        }
        $syncRemoteId = $resp.Arg0

        try {
            # SEND_V1: ID_SEND, path_len, "path,mode"
            $spec = "$remotePath,$mode"
            $specBytes = [System.Text.Encoding]::UTF8.GetBytes($spec)

            $sendReq = [byte[]]::new(8 + $specBytes.Length)
            [Buffer]::BlockCopy([BitConverter]::GetBytes([UsbAdbClient]::ID_SEND_V1), 0, $sendReq, 0, 4)
            [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$specBytes.Length), 0, $sendReq, 4, 4)
            [Buffer]::BlockCopy($specBytes, 0, $sendReq, 8, $specBytes.Length)
            $this.SendSyncWirePacket($syncLocalId, $syncRemoteId, $sendReq)

            # Stream chunks (up to 64KB)
            $offset = 0
            while ($offset -lt $fileBytes.Length) {
                $len = [Math]::Min([UsbAdbClient]::SYNC_DATA_MAX, $fileBytes.Length - $offset)
                $chunk = [byte[]]::new($len)
                [Buffer]::BlockCopy($fileBytes, $offset, $chunk, 0, $len)

                $dataReq = [byte[]]::new(8 + $len)
                [Buffer]::BlockCopy([BitConverter]::GetBytes([UsbAdbClient]::ID_DATA), 0, $dataReq, 0, 4)
                [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$len), 0, $dataReq, 4, 4)
                [Buffer]::BlockCopy($chunk, 0, $dataReq, 8, $len)
                $this.SendSyncWirePacket($syncLocalId, $syncRemoteId, $dataReq)
                $offset += $len
            }

            # Send DONE with timestamp
            $doneReq = [byte[]]::new(8)
            [Buffer]::BlockCopy([BitConverter]::GetBytes([UsbAdbClient]::ID_DONE), 0, $doneReq, 0, 4)
            $ts = [uint32][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            [Buffer]::BlockCopy([BitConverter]::GetBytes($ts), 0, $doneReq, 4, 4)
            $this.SendSyncWirePacket($syncLocalId, $syncRemoteId, $doneReq)

            # Read status response
            $statusBytes = $this.ReadSyncStreamBytes($syncLocalId, $syncRemoteId, 8)
            $statusId = [BitConverter]::ToUInt32($statusBytes, 0)
            $statusMsgLen = [BitConverter]::ToUInt32($statusBytes, 4)

            if ($statusId -eq [UsbAdbClient]::ID_OKAY) {
                # Success
            } elseif ($statusId -eq [UsbAdbClient]::ID_FAIL) {
                $errBytes = $this.ReadSyncStreamBytes($syncLocalId, $syncRemoteId, [int]$statusMsgLen)
                throw "SYNC push failed: $([System.Text.Encoding]::UTF8.GetString($errBytes))"
            } else {
                throw "Unexpected SYNC push response ID: 0x$($statusId.ToString('X8'))"
            }

            # Send QUIT
            $quitReq = [byte[]]::new(8)
            [Buffer]::BlockCopy([BitConverter]::GetBytes([UsbAdbClient]::ID_QUIT), 0, $quitReq, 0, 4)
            $this.SendSyncWirePacket($syncLocalId, $syncRemoteId, $quitReq)

        } finally {
            $this.CloseStream($syncLocalId, $syncRemoteId)
        }
    }

    [byte[]] PullBytes([string]$remotePath) {
        $this._syncRecvBuffer.Clear()
        $this._syncCanWrite = $true

        $syncLocalId = $this.OpenStream('sync:')
        $syncRemoteId = [uint32]0
        $resp = $this.ReadStreamMessage($syncLocalId)
        if ($resp.Command -ne [UsbAdbClient]::A_OKAY) {
            $this.CloseStream($syncLocalId, $resp.Arg0)
            throw "Failed to open sync stream: cmd=0x$($resp.Command.ToString('X8'))"
        }
        $syncRemoteId = $resp.Arg0

        try {
            # RECV_V1: ID_RECV, path_len, path
            $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($remotePath)
            $recvReq = [byte[]]::new(8 + $pathBytes.Length)
            [Buffer]::BlockCopy([BitConverter]::GetBytes([UsbAdbClient]::ID_RECV_V1), 0, $recvReq, 0, 4)
            [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$pathBytes.Length), 0, $recvReq, 4, 4)
            [Buffer]::BlockCopy($pathBytes, 0, $recvReq, 8, $pathBytes.Length)
            $this.SendSyncWirePacket($syncLocalId, $syncRemoteId, $recvReq)

            $ms = [System.IO.MemoryStream]::new()
            while ($true) {
                $hdr = $this.ReadSyncStreamBytes($syncLocalId, $syncRemoteId, 8)
                $chunkId = [BitConverter]::ToUInt32($hdr, 0)
                $chunkLen = [BitConverter]::ToUInt32($hdr, 4)

                if ($chunkId -eq [UsbAdbClient]::ID_DATA) {
                    $chunk = $this.ReadSyncStreamBytes($syncLocalId, $syncRemoteId, [int]$chunkLen)
                    $ms.Write($chunk, 0, $chunk.Length)
                } elseif ($chunkId -eq [UsbAdbClient]::ID_DONE) {
                    break
                } elseif ($chunkId -eq [UsbAdbClient]::ID_FAIL) {
                    $errBytes = $this.ReadSyncStreamBytes($syncLocalId, $syncRemoteId, [int]$chunkLen)
                    throw "SYNC pull failed: $([System.Text.Encoding]::UTF8.GetString($errBytes))"
                } else {
                    throw "Unexpected SYNC pull chunk ID: 0x$($chunkId.ToString('X8'))"
                }
            }

            # Send QUIT
            $quitReq = [byte[]]::new(8)
            [Buffer]::BlockCopy([BitConverter]::GetBytes([UsbAdbClient]::ID_QUIT), 0, $quitReq, 0, 4)
            $this.SendSyncWirePacket($syncLocalId, $syncRemoteId, $quitReq)

            return $ms.ToArray()

        } finally {
            $this.CloseStream($syncLocalId, $syncRemoteId)
        }
    }

    [void] PullFile([string]$remotePath, [string]$localPath) {
        $bytes = $this.PullBytes($remotePath)
        $dir = [System.IO.Path]::GetDirectoryName($localPath)
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllBytes($localPath, $bytes)
    }

    [void] Dispose() {
        if ($this._usbHandle -ne [IntPtr]::Zero) {
            [void]$this._native::WinUsb_Free($this._usbHandle)
            $this._usbHandle = [IntPtr]::Zero
        }
        if ($this._usbPin.IsAllocated) {
            $this._usbPin.Free()
        }
        if ($null -ne $this._devHandle) {
            $this._devHandle.Dispose()
            $this._devHandle = $null
        }
    }
}



# =============================================================================
# ADB service stream. Wire semantics: aosp-adb
# 1cf2f017d312f73b3dc53bda85ef2610e35a80e9, docs/dev/protocol.md.
# Synchronous calls use the connection holder's owning runspace. Dispose closes
# the service, not the shared device connection. Seeking is not supported.
# =============================================================================

class AdbStream : System.IO.Stream {
    [UsbAdbClient] $_client
    [uint32] $_localId
    [uint32] $_remoteId
    [string] $_token
    [bool] $_closed
    [bool] $_disposed
    [System.Collections.Generic.Queue[byte[]]] $_received = [System.Collections.Generic.Queue[byte[]]]::new()
    [byte[]] $_buffer = [byte[]]::new(0)
    [int] $_offset

    AdbStream([UsbAdbClient] $client, [string] $service) {
        if ([string]::IsNullOrWhiteSpace($service) -or $service.Contains([char]0)) {
            throw [ArgumentException]::new('A service must be nonempty and contain no NUL.')
        }
        $this._client = $client
        $this._localId = $client.OpenStream($service)
        try {
            $message = $client.ReadStreamMessage($this._localId)
            if ($message.Command -ne [UsbAdbClient]::A_OKAY -or $message.Arg0 -eq 0) {
                throw [IO.IOException]::new('The device rejected the service.')
            }
            $this._remoteId = $message.Arg0
        }
        catch { $client.CloseStream($this._localId, $this._remoteId); throw }
    }

    AdbStream([string] $token) { $this._token = $token }

    static [hashtable] Request([hashtable] $request) {
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', "pwsh-adb-$([Environment]::UserName)", [IO.Pipes.PipeDirection]::InOut)
        try {
            $pipe.Connect(15000)
            $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 4096, $true)
            $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 4096, $true)
            $writer.WriteLine(($request | ConvertTo-Json -Compress -Depth 5))
            $writer.Flush()
            $line = $reader.ReadLine()
            if ($null -eq $line) { throw [IO.IOException]::new('The ADB connection holder disconnected.') }
            $response = $line | ConvertFrom-Json -AsHashtable
            if ($response.Error) { throw [IO.IOException]::new([string]$response.Error) }
            return $response
        }
        finally { $pipe.Dispose() }
    }

    [bool] get_CanRead() { return -not $this._disposed }
    [bool] get_CanWrite() { return -not ($this._disposed -or $this._closed) }
    [bool] get_CanSeek() { return $false }
    [long] get_Length() { throw [NotSupportedException]::new() }
    [long] get_Position() { throw [NotSupportedException]::new() }
    [void] set_Position([long] $value) { throw [NotSupportedException]::new() }
    [long] Seek([long] $offset, [IO.SeekOrigin] $origin) { throw [NotSupportedException]::new() }
    [void] SetLength([long] $value) { throw [NotSupportedException]::new() }
    [void] Flush() {
        if ($this._disposed) { throw [ObjectDisposedException]::new('AdbStream') }
    }

    [void] ValidateBuffer([byte[]] $buffer, [int] $offset, [int] $count) {
        if ($this._disposed) { throw [ObjectDisposedException]::new('AdbStream') }
        if ($null -eq $buffer) { throw [ArgumentNullException]::new('buffer') }
        if ($offset -lt 0 -or $count -lt 0 -or $offset -gt $buffer.Length - $count) {
            throw [ArgumentOutOfRangeException]::new('offset/count')
        }
    }

    [void] Receive([UsbAdbWireMessage] $message) {
        if ($message.Command -eq [UsbAdbClient]::A_WRTE) {
            $this._client.SendWireMessage([UsbAdbClient]::A_OKAY, $this._localId, $this._remoteId, $null)
            if ($message.Data.Length -gt 0) { $this._received.Enqueue($message.Data) }
        }
        elseif ($message.Command -eq [UsbAdbClient]::A_CLSE) {
            $this._closed = $true
            $this._client.CloseStream($this._localId, $this._remoteId)
        }
    }

    [int] Read([byte[]] $buffer, [int] $offset, [int] $count) {
        $this.ValidateBuffer($buffer, $offset, $count)
        if ($count -eq 0) { return 0 }
        if ($this._token) {
            $response = [AdbStream]::Request(@{ Op = 'stream-read'; Token = $this._token; Count = [Math]::Min($count, 65536) })
            $bytes = [Convert]::FromBase64String([string]$response.Data)
            if ($bytes.Length -gt $count) { throw [IO.InvalidDataException]::new('Stream response exceeds requested length.') }
            [Buffer]::BlockCopy($bytes, 0, $buffer, $offset, $bytes.Length)
            return $bytes.Length
        }
        while ($this._offset -eq $this._buffer.Length) {
            if ($this._received.Count -gt 0) {
                $this._buffer = $this._received.Dequeue()
                $this._offset = 0
                break
            }
            if ($this._closed) { return 0 }
            $this.Receive($this._client.ReadStreamMessage($this._localId))
        }
        $take = [Math]::Min($count, $this._buffer.Length - $this._offset)
        [Buffer]::BlockCopy($this._buffer, $this._offset, $buffer, $offset, $take)
        $this._offset += $take
        return $take
    }

    [void] Write([byte[]] $buffer, [int] $offset, [int] $count) {
        $this.ValidateBuffer($buffer, $offset, $count)
        if ($this._closed) { throw [IO.IOException]::new('The device closed the service.') }
        while ($count -gt 0) {
            $limit = if ($this._token) { 65536 } else { [int]$this._client._maxPayload }
            $take = [Math]::Min($count, $limit)
            $bytes = [byte[]]::new($take)
            [Buffer]::BlockCopy($buffer, $offset, $bytes, 0, $take)
            if ($this._token) {
                [void][AdbStream]::Request(@{ Op = 'stream-write'; Token = $this._token; Data = [Convert]::ToBase64String($bytes) })
            }
            else {
                $this._client.SendWireMessage([UsbAdbClient]::A_WRTE, $this._localId, $this._remoteId, $bytes)
                do {
                    $message = $this._client.ReadStreamMessage($this._localId)
                    $this.Receive($message)
                    if ($this._closed) { throw [IO.IOException]::new('The device closed the service during a write.') }
                } while ($message.Command -ne [UsbAdbClient]::A_OKAY)
            }
            $offset += $take
            $count -= $take
        }
    }

    [void] Dispose([bool] $disposing) {
        if ($this._disposed) { return }
        try {
            if ($this._token) { [void][AdbStream]::Request(@{ Op = 'stream-close'; Token = $this._token }) }
            elseif (-not $this._closed) { $this._client.CloseStream($this._localId, $this._remoteId) }
        }
        finally { $this._disposed = $true; $this._closed = $true }
    }
}

# =============================================================================
# Device selection: the same rule for command and API calls.
# =============================================================================

function Select-UsbAdbDevice {
    <#
    .SYNOPSIS
        Selects one ADB USB device: the only one, a zero-based index, or a unique
        substring of its friendly name or instance ID.
    #>
    [CmdletBinding()]
    param([string] $Selector)
    $devices = @(Get-UsbAdbDevices)
    if ($devices.Count -eq 0) { throw 'No connected Android ADB USB interfaces detected.' }
    if ([string]::IsNullOrWhiteSpace($Selector)) {
        if ($devices.Count -eq 1) { return $devices[0] }
        $list = ($devices | ForEach-Object { '  [{0}] {1} ({2})' -f $_.Index, $_.FriendlyName, $_.RedactedInstanceId }) -join "`n"
        throw "Several ADB devices are attached; choose one with -Device <index|name>:`n$list"
    }
    if ($Selector -match '^\d+$') {
        $index = [int]$Selector
        if ($index -ge 0 -and $index -lt $devices.Count) { return $devices[$index] }
        throw "Device index '$index' is out of range (0..$($devices.Count - 1))."
    }
    $match = @($devices | Where-Object { $_.FriendlyName -like "*$Selector*" -or $_.InstanceId -like "*$Selector*" })
    if ($match.Count -eq 1) { return $match[0] }
    if ($match.Count -gt 1) { throw "Selector '$Selector' matched several devices; use the index." }
    throw "No device matched selector '$Selector'."
}

# =============================================================================
# Connection holder (Pwsh): one long-lived connection per device, like the
# adb server. A device that sees a second CNXN takes its transport offline,
# and some devices restart their USB function when that happens, so one-shot
# commands must not each open their own connection. Requests arrive over a
# named pipe that only the current user may open; the server blocks waiting
# for the next request and never polls.
# =============================================================================

$script:AdbPipeName = "pwsh-adb-$([Environment]::UserName)"

function Invoke-AdbClientOperation {
    # Runs one operation on an already connected client.
    param([Parameter(Mandatory)] $Client, [Parameter(Mandatory)] [hashtable] $Request, [hashtable] $Streams)
    switch ($Request.Op) {
        'stream-open' {
            $token = [Guid]::NewGuid().ToString('N')
            $Streams[$token] = [AdbStream]::new($Client, [string]$Request.Service)
            return @{ Token = $token; ExitCode = 0 }
        }
        'exec-out' {
            $stream = [AdbStream]::new($Client, "exec:$($Request.Command)")
            $memory = [IO.MemoryStream]::new()
            try {
                $stream.CopyTo($memory)
                return @{ Data = [Convert]::ToBase64String($memory.ToArray()); ExitCode = 0 }
            }
            finally { $stream.Dispose(); $memory.Dispose() }
        }
        'shell' {
            $r = $Client.ExecuteShell([string]$Request.Command)
            return @{ Stdout = [string]$r.Stdout; Stderr = [string]$r.Stderr; ExitCode = [int]$r.ExitCode }
        }
        'push' { $Client.PushFile([string]$Request.Path, [string]$Request.Destination); return @{ ExitCode = 0 } }
        'pull' { $Client.PullFile([string]$Request.Source, [string]$Request.Destination); return @{ ExitCode = 0 } }
        'install' {
            $remote = '/data/local/tmp/pwsh-install-{0}.apk' -f [Guid]::NewGuid().ToString('N')
            $Client.PushFile([string]$Request.Path, $remote)
            try {
                $flags = if ($Request.Replace) { '-r -t' } else { '-t' }
                $r = $Client.ExecuteShell("pm install $flags $remote")
                if ($r.ExitCode -ne 0 -or "$($r.Stdout)" -notmatch 'Success') {
                    throw "pm install failed (exit $($r.ExitCode)): $(("$($r.Stdout) $($r.Stderr)").Trim())"
                }
                return @{ Stdout = ([string]$r.Stdout).Trim(); ExitCode = 0 }
            }
            finally { [void]$Client.ExecuteShell("rm -f $remote") }
        }
        default { throw "Unknown operation '$($Request.Op)'." }
    }
}

function Start-AdbServer {
    <#
    .SYNOPSIS
        Starts the connection holder: in the background by default, or in this process with -Foreground.
    #>
    [CmdletBinding()]
    param([switch] $Foreground)
    if (-not $Foreground) {
        if (Test-AdbServer) { return }
        $self = Join-Path $PSScriptRoot 'adb.ps1'
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-File', "`"$self`"", 'start-server', '-Foreground') -WindowStyle Hidden | Out-Null
        $probe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $script:AdbPipeName, [System.IO.Pipes.PipeDirection]::InOut)
        try { $probe.Connect(15000) } finally { $probe.Dispose() }
        return
    }
    $security = [System.IO.Pipes.PipeSecurity]::new()
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $security.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new($user, [System.IO.Pipes.PipeAccessRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow))
    $clients = @{}
    $streams = @{}
    $running = $true
    while ($running) {
        $pipe = [System.IO.Pipes.NamedPipeServerStreamAcl]::Create($script:AdbPipeName, [System.IO.Pipes.PipeDirection]::InOut, 1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::None, 0, 0, $security)
        try {
            $pipe.WaitForConnection()
            $reader = [System.IO.StreamReader]::new($pipe, [System.Text.UTF8Encoding]::new($false), $false, 4096, $true)
            $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.UTF8Encoding]::new($false), 4096, $true)
            $line = $reader.ReadLine()
            if (-not $line) { continue }   # a connection probe with no request
            $request = $line | ConvertFrom-Json -AsHashtable
            $response = @{}
            try {
                switch ($request.Op) {
                    'kill' { $running = $false; $response = @{ ExitCode = 0 } }
                    'devices' {
                        $response = @{ ExitCode = 0; Devices = @(Get-UsbAdbDevices | ForEach-Object {
                            @{ Index = $_.Index; FriendlyName = $_.FriendlyName; RedactedInstanceId = $_.RedactedInstanceId
                               IsAccessible = $_.IsAccessible; AccessError = $_.AccessError; Connected = $clients.ContainsKey($_.InstanceId) } }) }
                    }
                    { $_ -in 'stream-read', 'stream-write', 'stream-close' } {
                        $serviceStream = $streams[[string]$request.Token]
                        if ($null -eq $serviceStream) { throw 'Unknown or closed service stream.' }
                        switch ($request.Op) {
                            'stream-read' {
                                $count = [int]$request.Count
                                if ($count -lt 0 -or $count -gt 65536) { throw 'Stream read length is outside 0..65536.' }
                                $bytes = [byte[]]::new($count)
                                $read = $serviceStream.Read($bytes, 0, $count)
                                $response = @{ Data = [Convert]::ToBase64String($bytes, 0, $read); ExitCode = 0 }
                            }
                            'stream-write' {
                                $bytes = [Convert]::FromBase64String([string]$request.Data)
                                if ($bytes.Length -gt 65536) { throw 'Stream write length exceeds 65536.' }
                                $serviceStream.Write($bytes, 0, $bytes.Length)
                                $response = @{ ExitCode = 0 }
                            }
                            'stream-close' {
                                try { $serviceStream.Dispose() }
                                finally { $streams.Remove([string]$request.Token) }
                                $response = @{ ExitCode = 0 }
                            }
                        }
                    }
                    default {
                        $device = Select-UsbAdbDevice -Selector ([string]$request.Device)
                        $client = $clients[$device.InstanceId]
                        if ($null -eq $client) {
                            $client = [UsbAdbClient]::new($device)
                            try { $client.Connect() } catch { $client.Dispose(); throw }
                            $clients[$device.InstanceId] = $client
                        }
                        try { $response = Invoke-AdbClientOperation -Client $client -Request $request -Streams $streams }
                        catch {
                            # The connection's state is unknown after a failure: drop it, so
                            # the next request reconnects (after a replug, if the device needs one).
                            $client.Dispose(); $clients.Remove($device.InstanceId); throw
                        }
                    }
                }
            }
            catch { $response = @{ ExitCode = -1; Error = $_.Exception.Message } }
            $writer.WriteLine(($response | ConvertTo-Json -Compress -Depth 5)); $writer.Flush()
        }
        catch [System.IO.IOException] { }   # the requester went away; wait for the next one
        finally { $pipe.Dispose() }
    }
    foreach ($s in $streams.Values) { try { $s.Dispose() } catch { } }
    foreach ($c in $clients.Values) { $c.Dispose() }
}

function Test-AdbServer {
    # True when the connection holder answers within 300 ms.
    $probe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $script:AdbPipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try { $probe.Connect(300); return $true } catch [TimeoutException] { return $false } finally { $probe.Dispose() }
}

function Invoke-AdbRequest {
    # Sends one request to the connection holder, starting it if needed.
    param([Parameter(Mandatory)] [hashtable] $Request)
    if (-not (Test-AdbServer)) { Start-AdbServer }
    [AdbStream]::Request($Request)
}

function Stop-AdbServer {
    <# .SYNOPSIS Stops the connection holder and closes every device connection. #>
    if (Test-AdbServer) { [void](Invoke-AdbRequest @{ Op = 'kill' }) }
}

# Command and API invocation use the same operations. -Api returns objects;
# exec-out returns one byte[]; stream always returns an owned .NET Stream.
$rest = [Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $CommandArgs.Count; $i++) {
    if ($CommandArgs[$i] -ceq '-s') {
        if (++$i -ge $CommandArgs.Count) { throw '-s requires a device index or name.' }
        $Device = $CommandArgs[$i]
    }
    else { $rest.Add($CommandArgs[$i]) }
}
$global:LASTEXITCODE = 0
switch ($Command) {
    'derive-pairing-key' {
        if (-not $Api -or $null -eq $KeyMaterial) { throw 'Use -Api -KeyMaterial <byte[]> for pairing key derivation.' }
        return ,([AdbPairingKey]::DeriveAesKey($KeyMaterial))
    }
    'start-server' {
        Start-AdbServer -Foreground:$Foreground
        if ($Api) { [pscustomobject]@{ Running = $true } }
        else { 'connection holder running' }
    }
    'kill-server' {
        Stop-AdbServer
        if ($Api) { [pscustomobject]@{ Running = $false } }
    }
    'devices' {
        $devices = (Invoke-AdbRequest @{ Op = 'devices' }).Devices
        if ($Api) { $devices | ForEach-Object { [pscustomobject]$_ } }
        else {
            'List of devices attached'
            foreach ($d in $devices) {
                $state = if ($d.IsAccessible -or $d.Connected) { 'device' } else { 'unavailable' }
                "[{0}] {1}`t{2}" -f $d.Index, $d.FriendlyName, $state
            }
        }
    }
    'shell' {
        if ($rest.Count -eq 0) { throw 'Usage: adb.ps1 shell [-s <device>] <command>' }
        $result = Invoke-AdbRequest @{ Op = 'shell'; Device = $Device; Command = $rest -join ' ' }
        $global:LASTEXITCODE = [int]$result.ExitCode
        if ($Api) { [pscustomobject]$result }
        else {
            [Console]::Out.Write([string]$result.Stdout)
            [Console]::Error.Write([string]$result.Stderr)
            exit $result.ExitCode
        }
    }
    'exec-out' {
        if ($rest.Count -eq 0) { throw 'Usage: adb.ps1 exec-out [-s <device>] <command>' }
        $result = Invoke-AdbRequest @{ Op = 'exec-out'; Device = $Device; Command = $rest -join ' ' }
        $bytes = [Convert]::FromBase64String([string]$result.Data)
        if ($Api) { return ,$bytes }
        [Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)
    }
    'stream' {
        if ($rest.Count -ne 1) { throw 'Usage: & adb.ps1 stream -Device <device> tcp:<port>|localabstract:<name>' }
        $result = Invoke-AdbRequest @{ Op = 'stream-open'; Device = $Device; Service = $rest[0] }
        return [AdbStream]::new([string]$result.Token)
    }
    'push' {
        if ($rest.Count -ne 2) { throw 'Usage: adb.ps1 push [-s <device>] <local> <remote>' }
        $path = (Resolve-Path -LiteralPath $rest[0]).Path
        $result = Invoke-AdbRequest @{ Op = 'push'; Device = $Device; Path = $path; Destination = $rest[1] }
        if ($Api) { [pscustomobject]$result }
        else { '{0}: 1 file pushed. {1} bytes' -f $rest[0], ([IO.FileInfo]$path).Length }
    }
    'pull' {
        if ($rest.Count -ne 2) { throw 'Usage: adb.ps1 pull [-s <device>] <remote> <local>' }
        $path = [IO.Path]::GetFullPath($rest[1])
        $result = Invoke-AdbRequest @{ Op = 'pull'; Device = $Device; Source = $rest[0]; Destination = $path }
        if ($Api) { [pscustomobject]$result }
        else { '{0}: 1 file pulled. {1} bytes' -f $rest[0], ([IO.FileInfo]$path).Length }
    }
    'install' {
        $paths = @($rest | Where-Object { $_ -notlike '-*' })
        if ($paths.Count -ne 1) { throw 'Usage: adb.ps1 install [-s <device>] [-r] <apk>' }
        $result = Invoke-AdbRequest @{ Op = 'install'; Device = $Device; Path = (Resolve-Path -LiteralPath $paths[0]).Path; Replace = $rest.Contains('-r') }
        if ($Api) { [pscustomobject]$result }
        else { $result.Stdout }
    }
    'pubkey' { [UsbAdbCrypto]::GetPublicKeyString() }
    'version' {
        $version = [pscustomobject]@{ Name = 'Android Debug Bridge in PowerShell'; Protocol = '0x01000001'; Transport = 'WinUSB' }
        if ($Api) { $version } else { "$($version.Name) ($($version.Transport)), protocol $($version.Protocol)" }
    }
    'help' {
        @'
Android Debug Bridge in PowerShell; all implementation is in this file.
  adb.ps1 devices [-l]
  adb.ps1 start-server | kill-server
  adb.ps1 shell|exec-out [-s <device>] <command>
  adb.ps1 push|pull [-s <device>] <source> <destination>
  adb.ps1 install [-s <device>] [-r] <apk>
  adb.ps1 pubkey | version
  & adb.ps1 <command> -Api -Device <index|name> ...  # objects; exec-out: byte[]
  & adb.ps1 stream -Device <index|name> <service>   # System.IO.Stream; Dispose when done
  & adb.ps1 derive-pairing-key -Api -KeyMaterial <byte[]>  # HKDF only; pairing pending
Synchronous stream operations share the connection holder; do not call concurrently.
'@
    }
}
