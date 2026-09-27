<#
    AndroidCanvas.psm1: draw on the NativeActivity window from PowerShell with
    Android's own Canvas, through JNI and NDK exports. One file, no other
    module, no cmdlet module: it uses the language, .NET and SMA only, so it
    runs in the Pwsh app's payload.

    Mechanism, bottom up:
      1. New-NativeFunction turns a function address and a signature into a
         typed delegate (one emitted delegate type per signature, the
         platform C calling convention).
      2. Get-NativeExport binds a shared-library export by name
         (NativeLibrary.Load and GetExport).
      3. The JNI table: JNIEnv* points to a table of function pointers whose
         slot numbers come from jni.h (see $JniSlot below); every call takes the
         env first.
      4. Canvas: the window's Surface (ANativeWindow_toSurface), lockCanvas,
         draw calls, unlockCanvasAndPost.
      5. Register-WindowDrawHandler writes callbacks into NativeActivity's
         callback table (native_activity.h: onNativeWindowCreated, slot 7;
         onNativeWindowRedrawNeeded, slot 9) so the window is drawn when
         Android creates it and whenever Android asks for a redraw.

    Threading: JNI and the callbacks use activity->env, which belongs to the
    main thread. Call these functions on the main thread only (Profile.ps1 and
    the window callbacks run there).

    Usage, from Profile.ps1 in the Pwsh app:
        Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AndroidCanvas.psm1'))
        Initialize-AndroidCanvas -NativeActivity $NativeActivityHandle
        Register-WindowDrawHandler {
            param($Canvas)
            Clear-Canvas $Canvas -Color (ConvertTo-ArgbColor 12 12 12)
            Add-CanvasText $Canvas 'Hello from PowerShell' -X 40 -Y 80 -Size 48 -Color (ConvertTo-ArgbColor 204 204 204)
        }
#>

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$Interop = [Runtime.InteropServices.Marshal]

# --- 1. Function pointers as delegates ----------------------------------------
$script:Emit = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
    [Reflection.AssemblyName]::new('AndroidCanvas.Delegates'), [Reflection.Emit.AssemblyBuilderAccess]::Run).DefineDynamicModule('Delegates')
$script:DelegateTypes = @{}

function Get-NativeDelegateType {
    param([Parameter(Mandatory)][type] $Return, [type[]] $Parameters = @())
    $key = $Return.FullName + '(' + (@(foreach ($t in $Parameters) { $t.FullName }) -join ',') + ')'
    if (-not $script:DelegateTypes.ContainsKey($key)) {
        $b = $script:Emit.DefineType("AndroidCanvas.Call$($script:DelegateTypes.Count)", [Reflection.TypeAttributes]'Public,Sealed', [MulticastDelegate])
        $b.DefineConstructor([Reflection.MethodAttributes]'Public,HideBySig,SpecialName,RTSpecialName', [Reflection.CallingConventions]::Standard,
            [type[]]@([object], [IntPtr])).SetImplementationFlags([Reflection.MethodImplAttributes]'Runtime,Managed')
        $b.DefineMethod('Invoke', [Reflection.MethodAttributes]'Public,HideBySig,NewSlot,Virtual', $Return, $Parameters).SetImplementationFlags(
            [Reflection.MethodImplAttributes]'Runtime,Managed')
        $script:DelegateTypes[$key] = $b.CreateType()
    }
    $script:DelegateTypes[$key]
}

function New-NativeFunction {
    param([Parameter(Mandatory)][IntPtr] $Address, [Parameter(Mandatory)][type] $Return, [type[]] $Parameters = @())
    if ($Address -eq [IntPtr]::Zero) { throw 'Cannot bind a null function address.' }
    $Interop::GetDelegateForFunctionPointer($Address, (Get-NativeDelegateType $Return $Parameters))
}

# --- 2. Shared-library exports -------------------------------------------------
$script:Libraries = @{}
function Get-NativeExport {
    param([Parameter(Mandatory)][string] $Library, [Parameter(Mandatory)][string] $Name,
          [Parameter(Mandatory)][type] $Return, [type[]] $Parameters = @())
    if (-not $script:Libraries.ContainsKey($Library)) { $script:Libraries[$Library] = [Runtime.InteropServices.NativeLibrary]::Load($Library) }
    New-NativeFunction ([Runtime.InteropServices.NativeLibrary]::GetExport($script:Libraries[$Library], $Name)) $Return $Parameters
}

$I = [IntPtr]
$script:LogWrite = Get-NativeExport 'liblog.so' '__android_log_write' ([int]) @([int], $I, $I)
function Write-AndroidLog {
    param([Parameter(Mandatory)][string] $Text, [int] $Priority = 4, [string] $Tag = 'Pwsh')
    $t = $Interop::StringToCoTaskMemUTF8($Tag); $m = $Interop::StringToCoTaskMemUTF8($Text)
    try { [void]$script:LogWrite.Invoke($Priority, $t, $m) } finally { $Interop::FreeCoTaskMem($t); $Interop::FreeCoTaskMem($m) }
}

# --- 3. JNI ----------------------------------------------------------------------
# JNINativeInterface slots, generated from jni.h SHA-256 C88CE2CB6CE10378CD4C706A3A2AD017794AEDB9314DDCC341E39B470CDB601A
# (AOSP libnativehelper af5fd77f, include_jni/jni.h, 233 entries). Do not edit
# by hand.
$script:JniSlot = @{
    GetVersion = 4
    DefineClass = 5
    FindClass = 6
    FromReflectedMethod = 7
    FromReflectedField = 8
    ToReflectedMethod = 9
    GetSuperclass = 10
    IsAssignableFrom = 11
    ToReflectedField = 12
    Throw = 13
    ThrowNew = 14
    ExceptionOccurred = 15
    ExceptionDescribe = 16
    ExceptionClear = 17
    FatalError = 18
    PushLocalFrame = 19
    PopLocalFrame = 20
    NewGlobalRef = 21
    DeleteGlobalRef = 22
    DeleteLocalRef = 23
    IsSameObject = 24
    NewLocalRef = 25
    EnsureLocalCapacity = 26
    AllocObject = 27
    NewObject = 28
    NewObjectV = 29
    NewObjectA = 30
    GetObjectClass = 31
    IsInstanceOf = 32
    GetMethodID = 33
    CallObjectMethod = 34
    CallObjectMethodV = 35
    CallObjectMethodA = 36
    CallBooleanMethod = 37
    CallBooleanMethodV = 38
    CallBooleanMethodA = 39
    CallByteMethod = 40
    CallByteMethodV = 41
    CallByteMethodA = 42
    CallCharMethod = 43
    CallCharMethodV = 44
    CallCharMethodA = 45
    CallShortMethod = 46
    CallShortMethodV = 47
    CallShortMethodA = 48
    CallIntMethod = 49
    CallIntMethodV = 50
    CallIntMethodA = 51
    CallLongMethod = 52
    CallLongMethodV = 53
    CallLongMethodA = 54
    CallFloatMethod = 55
    CallFloatMethodV = 56
    CallFloatMethodA = 57
    CallDoubleMethod = 58
    CallDoubleMethodV = 59
    CallDoubleMethodA = 60
    CallVoidMethod = 61
    CallVoidMethodV = 62
    CallVoidMethodA = 63
    CallNonvirtualObjectMethod = 64
    CallNonvirtualObjectMethodV = 65
    CallNonvirtualObjectMethodA = 66
    CallNonvirtualBooleanMethod = 67
    CallNonvirtualBooleanMethodV = 68
    CallNonvirtualBooleanMethodA = 69
    CallNonvirtualByteMethod = 70
    CallNonvirtualByteMethodV = 71
    CallNonvirtualByteMethodA = 72
    CallNonvirtualCharMethod = 73
    CallNonvirtualCharMethodV = 74
    CallNonvirtualCharMethodA = 75
    CallNonvirtualShortMethod = 76
    CallNonvirtualShortMethodV = 77
    CallNonvirtualShortMethodA = 78
    CallNonvirtualIntMethod = 79
    CallNonvirtualIntMethodV = 80
    CallNonvirtualIntMethodA = 81
    CallNonvirtualLongMethod = 82
    CallNonvirtualLongMethodV = 83
    CallNonvirtualLongMethodA = 84
    CallNonvirtualFloatMethod = 85
    CallNonvirtualFloatMethodV = 86
    CallNonvirtualFloatMethodA = 87
    CallNonvirtualDoubleMethod = 88
    CallNonvirtualDoubleMethodV = 89
    CallNonvirtualDoubleMethodA = 90
    CallNonvirtualVoidMethod = 91
    CallNonvirtualVoidMethodV = 92
    CallNonvirtualVoidMethodA = 93
    GetFieldID = 94
    GetObjectField = 95
    GetBooleanField = 96
    GetByteField = 97
    GetCharField = 98
    GetShortField = 99
    GetIntField = 100
    GetLongField = 101
    GetFloatField = 102
    GetDoubleField = 103
    SetObjectField = 104
    SetBooleanField = 105
    SetByteField = 106
    SetCharField = 107
    SetShortField = 108
    SetIntField = 109
    SetLongField = 110
    SetFloatField = 111
    SetDoubleField = 112
    GetStaticMethodID = 113
    CallStaticObjectMethod = 114
    CallStaticObjectMethodV = 115
    CallStaticObjectMethodA = 116
    CallStaticBooleanMethod = 117
    CallStaticBooleanMethodV = 118
    CallStaticBooleanMethodA = 119
    CallStaticByteMethod = 120
    CallStaticByteMethodV = 121
    CallStaticByteMethodA = 122
    CallStaticCharMethod = 123
    CallStaticCharMethodV = 124
    CallStaticCharMethodA = 125
    CallStaticShortMethod = 126
    CallStaticShortMethodV = 127
    CallStaticShortMethodA = 128
    CallStaticIntMethod = 129
    CallStaticIntMethodV = 130
    CallStaticIntMethodA = 131
    CallStaticLongMethod = 132
    CallStaticLongMethodV = 133
    CallStaticLongMethodA = 134
    CallStaticFloatMethod = 135
    CallStaticFloatMethodV = 136
    CallStaticFloatMethodA = 137
    CallStaticDoubleMethod = 138
    CallStaticDoubleMethodV = 139
    CallStaticDoubleMethodA = 140
    CallStaticVoidMethod = 141
    CallStaticVoidMethodV = 142
    CallStaticVoidMethodA = 143
    GetStaticFieldID = 144
    GetStaticObjectField = 145
    GetStaticBooleanField = 146
    GetStaticByteField = 147
    GetStaticCharField = 148
    GetStaticShortField = 149
    GetStaticIntField = 150
    GetStaticLongField = 151
    GetStaticFloatField = 152
    GetStaticDoubleField = 153
    SetStaticObjectField = 154
    SetStaticBooleanField = 155
    SetStaticByteField = 156
    SetStaticCharField = 157
    SetStaticShortField = 158
    SetStaticIntField = 159
    SetStaticLongField = 160
    SetStaticFloatField = 161
    SetStaticDoubleField = 162
    NewString = 163
    GetStringLength = 164
    GetStringChars = 165
    ReleaseStringChars = 166
    NewStringUTF = 167
    GetStringUTFLength = 168
    GetStringUTFChars = 169
    ReleaseStringUTFChars = 170
    GetArrayLength = 171
    NewObjectArray = 172
    GetObjectArrayElement = 173
    SetObjectArrayElement = 174
    NewBooleanArray = 175
    NewByteArray = 176
    NewCharArray = 177
    NewShortArray = 178
    NewIntArray = 179
    NewLongArray = 180
    NewFloatArray = 181
    NewDoubleArray = 182
    GetBooleanArrayElements = 183
    GetByteArrayElements = 184
    GetCharArrayElements = 185
    GetShortArrayElements = 186
    GetIntArrayElements = 187
    GetLongArrayElements = 188
    GetFloatArrayElements = 189
    GetDoubleArrayElements = 190
    ReleaseBooleanArrayElements = 191
    ReleaseByteArrayElements = 192
    ReleaseCharArrayElements = 193
    ReleaseShortArrayElements = 194
    ReleaseIntArrayElements = 195
    ReleaseLongArrayElements = 196
    ReleaseFloatArrayElements = 197
    ReleaseDoubleArrayElements = 198
    GetBooleanArrayRegion = 199
    GetByteArrayRegion = 200
    GetCharArrayRegion = 201
    GetShortArrayRegion = 202
    GetIntArrayRegion = 203
    GetLongArrayRegion = 204
    GetFloatArrayRegion = 205
    GetDoubleArrayRegion = 206
    SetBooleanArrayRegion = 207
    SetByteArrayRegion = 208
    SetCharArrayRegion = 209
    SetShortArrayRegion = 210
    SetIntArrayRegion = 211
    SetLongArrayRegion = 212
    SetFloatArrayRegion = 213
    SetDoubleArrayRegion = 214
    RegisterNatives = 215
    UnregisterNatives = 216
    MonitorEnter = 217
    MonitorExit = 218
    GetJavaVM = 219
    GetStringRegion = 220
    GetStringUTFRegion = 221
    GetPrimitiveArrayCritical = 222
    ReleasePrimitiveArrayCritical = 223
    GetStringCritical = 224
    ReleaseStringCritical = 225
    NewWeakGlobalRef = 226
    DeleteWeakGlobalRef = 227
    ExceptionCheck = 228
    NewDirectByteBuffer = 229
    GetDirectBufferAddress = 230
    GetDirectBufferCapacity = 231
    GetObjectRefType = 232
}
$script:Jni = @{}
$script:JniEnv = [IntPtr]::Zero

function Get-JniFunction {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][type] $Return, [type[]] $Parameters = @())
    $table = $Interop::ReadIntPtr($script:JniEnv, 0)
    New-NativeFunction ($Interop::ReadIntPtr($table, $script:JniSlot[$Name] * [IntPtr]::Size)) $Return (@([IntPtr]) + $Parameters)
}

function Assert-NoJavaException([string] $Step) {
    if ($script:Jni.ExceptionCheck.Invoke($script:JniEnv) -ne 0) {
        $script:Jni.ExceptionDescribe.Invoke($script:JniEnv); $script:Jni.ExceptionClear.Invoke($script:JniEnv)
        throw "Java exception at $Step"
    }
}

function Invoke-WithUtf8([string[]] $Text, [scriptblock] $Body) {
    $p = @(foreach ($t in $Text) { $Interop::StringToCoTaskMemUTF8($t) })
    try { & $Body @p } finally { foreach ($q in $p) { $Interop::FreeCoTaskMem($q) } }
}

function Get-JavaClass {
    param([Parameter(Mandatory)][string] $Name)
    $local = Invoke-WithUtf8 $Name { param($n) $script:Jni.FindClass.Invoke($script:JniEnv, $n) }
    Assert-NoJavaException $Name
    $ref = $script:Jni.NewGlobalRef.Invoke($script:JniEnv, $local); $script:Jni.DeleteLocalRef.Invoke($script:JniEnv, $local)
    [IntPtr]$ref
}

function Get-JavaMethod {
    param([Parameter(Mandatory)][IntPtr] $Class, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Signature, [switch] $Static)
    $f = if ($Static) { $script:Jni.GetStaticMethodID } else { $script:Jni.GetMethodID }
    $id = Invoke-WithUtf8 $Name, $Signature { param($n, $s) $f.Invoke($script:JniEnv, $Class, $n, $s) }
    Assert-NoJavaException "$Name$Signature"; [IntPtr]$id
}

function Get-JavaField {
    param([Parameter(Mandatory)][IntPtr] $Class, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Signature, [switch] $Static)
    $f = if ($Static) { $script:Jni.GetStaticFieldID } else { $script:Jni.GetFieldID }
    $id = Invoke-WithUtf8 $Name, $Signature { param($n, $s) $f.Invoke($script:JniEnv, $Class, $n, $s) }
    Assert-NoJavaException "$Name$Signature"; [IntPtr]$id
}

function New-JavaString([string] $Text) {
    $s = Invoke-WithUtf8 $Text { param($t) $script:Jni.NewStringUTF.Invoke($script:JniEnv, $t) }
    Assert-NoJavaException 'NewStringUTF'; [IntPtr]$s
}

function Remove-JavaLocalRef([IntPtr] $Ref) { if ($Ref -ne [IntPtr]::Zero) { $script:Jni.DeleteLocalRef.Invoke($script:JniEnv, $Ref) } }

# Calls a JNI function whose last parameter is a jvalue[]; each argument is
# written by its .NET type: int, long, float, double, bool, IntPtr (an object).
function Invoke-JavaCall {
    param([Parameter(Mandatory)][Delegate] $Function, [Parameter(Mandatory)][IntPtr] $Target,
          [Parameter(Mandatory)][IntPtr] $Method, [object[]] $Arguments = @())
    $v = $Interop::AllocHGlobal([Math]::Max(8, 8 * $Arguments.Count))
    try {
        for ($i = 0; $i -lt $Arguments.Count; $i++) {
            $o = 8 * $i; $a = $Arguments[$i]; $Interop::WriteInt64($v, $o, 0)
            if ($a -is [int]) { $Interop::WriteInt32($v, $o, $a) }
            elseif ($a -is [long]) { $Interop::WriteInt64($v, $o, $a) }
            elseif ($a -is [float]) { $Interop::WriteInt32($v, $o, [BitConverter]::SingleToInt32Bits($a)) }
            elseif ($a -is [double]) { $Interop::WriteInt64($v, $o, [BitConverter]::DoubleToInt64Bits($a)) }
            elseif ($a -is [bool]) { $Interop::WriteByte($v, $o, [byte]$a) }
            elseif ($a -is [IntPtr]) { $Interop::WriteIntPtr($v, $o, $a) }
            else { throw "No jvalue mapping for $($a.GetType().FullName)." }
        }
        $r = $Function.Invoke($script:JniEnv, $Target, $Method, $v)
        Assert-NoJavaException 'call'
        $r
    }
    finally { $Interop::FreeHGlobal($v) }
}

# --- 4. Canvas -------------------------------------------------------------------
$script:K = $null
$script:Paint = [IntPtr]::Zero

function ConvertTo-ArgbColor {
    param([byte] $R, [byte] $G, [byte] $B, [byte] $A = 255)
    [BitConverter]::ToInt32([byte[]]@($B, $G, $R, $A), 0)   # the signed int Android color APIs take
}

function Initialize-AndroidCanvas {
    <# Binds JNI on activity->env and resolves the Canvas, Paint and Surface members this module uses. Call once, on the main thread. #>
    param([Parameter(Mandatory)][IntPtr] $NativeActivity)
    $script:Activity = $NativeActivity
    $script:JniEnv = $Interop::ReadIntPtr($NativeActivity, 2 * [IntPtr]::Size)   # callbacks, vm, env, clazz, ...
    $b = [byte]; $f = [float]; $v = [void]
    $script:Jni = @{
        ExceptionCheck = Get-JniFunction ExceptionCheck $b
        ExceptionDescribe = Get-JniFunction ExceptionDescribe $v
        ExceptionClear = Get-JniFunction ExceptionClear $v
        FindClass = Get-JniFunction FindClass $I @($I)
        NewGlobalRef = Get-JniFunction NewGlobalRef $I @($I)
        DeleteLocalRef = Get-JniFunction DeleteLocalRef $v @($I)
        GetMethodID = Get-JniFunction GetMethodID $I @($I, $I, $I)
        GetStaticMethodID = Get-JniFunction GetStaticMethodID $I @($I, $I, $I)
        GetFieldID = Get-JniFunction GetFieldID $I @($I, $I, $I)
        GetStaticFieldID = Get-JniFunction GetStaticFieldID $I @($I, $I, $I)
        GetStaticObjectField = Get-JniFunction GetStaticObjectField $I @($I, $I)
        GetStaticIntField = Get-JniFunction GetStaticIntField ([int]) @($I, $I)
        NewStringUTF = Get-JniFunction NewStringUTF $I @($I)
        NewObjectA = Get-JniFunction NewObjectA $I @($I, $I, $I)
        CallObjectMethodA = Get-JniFunction CallObjectMethodA $I @($I, $I, $I)
        CallVoidMethodA = Get-JniFunction CallVoidMethodA $v @($I, $I, $I)
        CallIntMethodA = Get-JniFunction CallIntMethodA ([int]) @($I, $I, $I)
        CallFloatMethodA = Get-JniFunction CallFloatMethodA $f @($I, $I, $I)
        CallStaticIntMethodA = Get-JniFunction CallStaticIntMethodA ([int]) @($I, $I, $I)
        GetIntField = Get-JniFunction GetIntField ([int]) @($I, $I)
        GetStringUTFChars = Get-JniFunction GetStringUTFChars $I @($I, $I)
        ReleaseStringUTFChars = Get-JniFunction ReleaseStringUTFChars $v @($I, $I)
        CallBooleanMethodA = Get-JniFunction CallBooleanMethodA $b @($I, $I, $I)
        CallStaticObjectMethodA = Get-JniFunction CallStaticObjectMethodA $I @($I, $I, $I)
    }
    $script:ToSurface = Get-NativeExport 'libandroid.so' 'ANativeWindow_toSurface' $I @($I, $I)
    $script:SetGeometry = Get-NativeExport 'libandroid.so' 'ANativeWindow_setBuffersGeometry' ([int]) @($I, [int], [int], [int])
    # Input queue and looper (include/android/input.h, looper.h at frameworks/native bfcf7507).
    $script:Input = @{
        ForThread = Get-NativeExport 'libandroid.so' 'ALooper_forThread' $I
        Attach = Get-NativeExport 'libandroid.so' 'AInputQueue_attachLooper' ([void]) @($I, $I, [int], $I, $I)
        Detach = Get-NativeExport 'libandroid.so' 'AInputQueue_detachLooper' ([void]) @($I)
        GetEvent = Get-NativeExport 'libandroid.so' 'AInputQueue_getEvent' ([int]) @($I, $I)
        PreDispatch = Get-NativeExport 'libandroid.so' 'AInputQueue_preDispatchEvent' ([int]) @($I, $I)
        Finish = Get-NativeExport 'libandroid.so' 'AInputQueue_finishEvent' ([void]) @($I, $I, [int])
        EventType = Get-NativeExport 'libandroid.so' 'AInputEvent_getType' ([int]) @($I)
        MotionAction = Get-NativeExport 'libandroid.so' 'AMotionEvent_getAction' ([int]) @($I)
        MotionX = Get-NativeExport 'libandroid.so' 'AMotionEvent_getX' ([float]) @($I, $I)
        MotionY = Get-NativeExport 'libandroid.so' 'AMotionEvent_getY' ([float]) @($I, $I)
        PointerCount = Get-NativeExport 'libandroid.so' 'AMotionEvent_getPointerCount' $I @($I)
        KeyAction = Get-NativeExport 'libandroid.so' 'AKeyEvent_getAction' ([int]) @($I)
        KeyCode = Get-NativeExport 'libandroid.so' 'AKeyEvent_getKeyCode' ([int]) @($I)
    }
    $script:EventSlot = $Interop::AllocHGlobal([IntPtr]::Size)   # AInputEvent** for getEvent, reused
    $surface = Get-JavaClass 'android/view/Surface'; $canvas = Get-JavaClass 'android/graphics/Canvas'
    $paint = Get-JavaClass 'android/graphics/Paint'; $typeface = Get-JavaClass 'android/graphics/Typeface'
    $mono = $script:Jni.GetStaticObjectField.Invoke($script:JniEnv, $typeface, (Get-JavaField $typeface 'MONOSPACE' 'Landroid/graphics/Typeface;' -Static))
    $script:K = @{
        LockCanvas = Get-JavaMethod $surface 'lockCanvas' '(Landroid/graphics/Rect;)Landroid/graphics/Canvas;'
        UnlockCanvasAndPost = Get-JavaMethod $surface 'unlockCanvasAndPost' '(Landroid/graphics/Canvas;)V'
        GetWidth = Get-JavaMethod $canvas 'getWidth' '()I'
        GetHeight = Get-JavaMethod $canvas 'getHeight' '()I'
        DrawColor = Get-JavaMethod $canvas 'drawColor' '(I)V'
        DrawRect = Get-JavaMethod $canvas 'drawRect' '(FFFFLandroid/graphics/Paint;)V'
        DrawText = Get-JavaMethod $canvas 'drawText' '(Ljava/lang/String;FFLandroid/graphics/Paint;)V'
        SetColor = Get-JavaMethod $paint 'setColor' '(I)V'
        SetTextSize = Get-JavaMethod $paint 'setTextSize' '(F)V'
        SetTypeface = Get-JavaMethod $paint 'setTypeface' '(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;'
        MeasureText = Get-JavaMethod $paint 'measureText' '(Ljava/lang/String;)F'
        GetFontSpacing = Get-JavaMethod $paint 'getFontSpacing' '()F'
    }
    # One Paint for the module's lifetime: antialiased, monospace.
    $flag = $script:Jni.GetStaticIntField.Invoke($script:JniEnv, $paint, (Get-JavaField $paint 'ANTI_ALIAS_FLAG' 'I' -Static))
    $local = Invoke-JavaCall $script:Jni.NewObjectA $paint (Get-JavaMethod $paint '<init>' '(I)V') @([int]$flag)
    $script:Paint = $script:Jni.NewGlobalRef.Invoke($script:JniEnv, $local); Remove-JavaLocalRef $local
    [void](Invoke-JavaCall $script:Jni.CallObjectMethodA $script:Paint $script:K.SetTypeface @([IntPtr]$mono))
}

function Get-CanvasSize {
    param([Parameter(Mandatory)][IntPtr] $Canvas)
    [pscustomobject]@{
        Width = Invoke-JavaCall $script:Jni.CallIntMethodA $Canvas $script:K.GetWidth
        Height = Invoke-JavaCall $script:Jni.CallIntMethodA $Canvas $script:K.GetHeight
    }
}

function Get-TextCell {
    <# The monospace cell size at a text size: width of 'M' and the font's line spacing, in pixels. #>
    param([Parameter(Mandatory)][float] $Size)
    Invoke-JavaCall $script:Jni.CallVoidMethodA $script:Paint $script:K.SetTextSize @([float]$Size)
    $m = New-JavaString 'M'
    try {
        [pscustomobject]@{
            Width = Invoke-JavaCall $script:Jni.CallFloatMethodA $script:Paint $script:K.MeasureText @([IntPtr]$m)
            Height = Invoke-JavaCall $script:Jni.CallFloatMethodA $script:Paint $script:K.GetFontSpacing
        }
    }
    finally { Remove-JavaLocalRef $m }
}

function Clear-Canvas {
    param([Parameter(Mandatory)][IntPtr] $Canvas, [Parameter(Mandatory)][int] $Color)
    Invoke-JavaCall $script:Jni.CallVoidMethodA $Canvas $script:K.DrawColor @($Color)
}

function Add-CanvasRect {
    param([Parameter(Mandatory)][IntPtr] $Canvas, [float] $Left, [float] $Top, [float] $Right, [float] $Bottom, [Parameter(Mandatory)][int] $Color)
    Invoke-JavaCall $script:Jni.CallVoidMethodA $script:Paint $script:K.SetColor @($Color)
    Invoke-JavaCall $script:Jni.CallVoidMethodA $Canvas $script:K.DrawRect @($Left, $Top, $Right, $Bottom, [IntPtr]$script:Paint)
}

function Add-CanvasText {
    param([Parameter(Mandatory)][IntPtr] $Canvas, [Parameter(Mandatory)][string] $Text, [float] $X, [float] $Y,
          [float] $Size = 32, [Parameter(Mandatory)][int] $Color)
    Invoke-JavaCall $script:Jni.CallVoidMethodA $script:Paint $script:K.SetColor @($Color)
    Invoke-JavaCall $script:Jni.CallVoidMethodA $script:Paint $script:K.SetTextSize @($Size)
    $s = New-JavaString $Text
    try { Invoke-JavaCall $script:Jni.CallVoidMethodA $Canvas $script:K.DrawText @([IntPtr]$s, $X, $Y, [IntPtr]$script:Paint) }
    finally { Remove-JavaLocalRef $s }
}

function Invoke-CanvasFrame {
    <# Locks a Canvas on the window, runs $Draw with it, and posts the frame. #>
    param([Parameter(Mandatory)][IntPtr] $Window, [Parameter(Mandatory)][scriptblock] $Draw)
    [void]$script:SetGeometry.Invoke($Window, 0, 0, 1)                 # WINDOW_FORMAT_RGBA_8888 (native_window.h)
    $surface = $script:ToSurface.Invoke($script:JniEnv, $Window)
    $canvas = Invoke-JavaCall $script:Jni.CallObjectMethodA $surface $script:K.LockCanvas @([IntPtr]::Zero)
    try { & $Draw $canvas }
    finally {
        Invoke-JavaCall $script:Jni.CallVoidMethodA $surface $script:K.UnlockCanvasAndPost @([IntPtr]$canvas)
        Remove-JavaLocalRef $canvas; Remove-JavaLocalRef $surface
    }
}

# --- 5. Window callbacks ------------------------------------------------------------
$script:Callbacks = @()
$script:InsetIds = $null
$script:InputQueue = [IntPtr]::Zero
$script:HandleInput = $null
$script:InputCallbacks = @()
$script:AfterInput = $null
$script:ClipIds = $null
$script:HapticIds = @{}
$script:Audio = $null
$script:Timer = $null
$script:Draw = $null
$script:Window = [IntPtr]::Zero

function Request-WindowDraw {
    <# Draws the window again with the registered draw handler, now, on the calling (main) thread. Call it after a state change; nothing redraws on its own. #>
    if ($script:Window -ne [IntPtr]::Zero -and $null -ne $script:Draw) { Invoke-CanvasFrame $script:Window $script:Draw }
}
function Register-WindowDrawHandler {
    <# Draws with $Draw when Android creates the window and whenever it asks for a redraw. #>
    param([Parameter(Mandatory)][scriptblock] $Draw)
    $script:Draw = $Draw
    $type = Get-NativeDelegateType ([void]) @([IntPtr], [IntPtr])
    $handler = { param([IntPtr] $Activity, [IntPtr] $Window)
        # Nothing may escape: an exception that reaches the native caller
        # aborts the process.
        try { $script:Window = $Window; Invoke-CanvasFrame $Window $script:Draw }
        catch { try { Write-AndroidLog ('AndroidCanvas: ' + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message) 6 } catch { } } }
    $created = [Management.Automation.LanguagePrimitives]::ConvertTo($handler, $type)
    $redraw = [Management.Automation.LanguagePrimitives]::ConvertTo($handler, $type)
    $script:Callbacks = @($created, $redraw)                          # rooted for the process lifetime
    $table = $Interop::ReadIntPtr($script:Activity, 0)
    $Interop::WriteIntPtr($table, 7 * [IntPtr]::Size, $Interop::GetFunctionPointerForDelegate($created))   # onNativeWindowCreated
    $Interop::WriteIntPtr($table, 9 * [IntPtr]::Size, $Interop::GetFunctionPointerForDelegate($redraw))    # onNativeWindowRedrawNeeded
}

# --- 6. System-bar insets ------------------------------------------------------------

function Get-SystemBarInsets {
    <# The window's system-bar insets in pixels (WindowInsets.Type.systemBars, API 30), or with -Gestures the zones Android reserves for its edge gestures (systemGestures); zeros before the window is attached. #>
    param([switch] $Gestures)
    $e = $script:JniEnv; $j = $script:Jni
    if ($null -eq $script:InsetIds) {
        $activity = Get-JavaClass 'android/app/Activity'; $window = Get-JavaClass 'android/view/Window'
        $view = Get-JavaClass 'android/view/View'; $insets = Get-JavaClass 'android/view/WindowInsets'
        $type = Get-JavaClass 'android/view/WindowInsets$Type'; $box = Get-JavaClass 'android/graphics/Insets'
        $script:InsetIds = @{
            GetWindow = Get-JavaMethod $activity 'getWindow' '()Landroid/view/Window;'
            GetDecorView = Get-JavaMethod $window 'getDecorView' '()Landroid/view/View;'
            GetRootWindowInsets = Get-JavaMethod $view 'getRootWindowInsets' '()Landroid/view/WindowInsets;'
            TypeClass = $type
            SystemBars = Get-JavaMethod $type 'systemBars' '()I' -Static
            SystemGestures = Get-JavaMethod $type 'systemGestures' '()I' -Static
            GetInsets = Get-JavaMethod $insets 'getInsets' '(I)Landroid/graphics/Insets;'
            Left = Get-JavaField $box 'left' 'I'; Top = Get-JavaField $box 'top' 'I'
            Right = Get-JavaField $box 'right' 'I'; Bottom = Get-JavaField $box 'bottom' 'I'
        }
    }
    $k = $script:InsetIds
    $activityObject = $Interop::ReadIntPtr($script:Activity, 3 * [IntPtr]::Size)   # ANativeActivity.clazz
    $window = Invoke-JavaCall $j.CallObjectMethodA $activityObject $k.GetWindow
    $decor = Invoke-JavaCall $j.CallObjectMethodA $window $k.GetDecorView
    $root = Invoke-JavaCall $j.CallObjectMethodA $decor $k.GetRootWindowInsets
    $result = [pscustomobject]@{ Left = 0; Top = 0; Right = 0; Bottom = 0 }
    if ($root -ne [IntPtr]::Zero) {
        $mask = Invoke-JavaCall $j.CallStaticIntMethodA $k.TypeClass $(if ($Gestures) { $k.SystemGestures } else { $k.SystemBars })
        $box = Invoke-JavaCall $j.CallObjectMethodA $root $k.GetInsets @([int]$mask)
        $result = [pscustomobject]@{
            Left = $j.GetIntField.Invoke($e, $box, $k.Left); Top = $j.GetIntField.Invoke($e, $box, $k.Top)
            Right = $j.GetIntField.Invoke($e, $box, $k.Right); Bottom = $j.GetIntField.Invoke($e, $box, $k.Bottom)
        }
        Remove-JavaLocalRef $box; Remove-JavaLocalRef $root
    }
    Remove-JavaLocalRef $decor; Remove-JavaLocalRef $window
    $result
}

# --- 7. Clipboard, haptics and a looper timer --------------------------------------------

function ConvertFrom-JavaString([IntPtr] $JString) {
    if ($JString -eq [IntPtr]::Zero) { return '' }
    $chars = $script:Jni.GetStringUTFChars.Invoke($script:JniEnv, $JString, [IntPtr]::Zero); Assert-NoJavaException 'GetStringUTFChars'
    try { $Interop::PtrToStringUTF8($chars) } finally { $script:Jni.ReleaseStringUTFChars.Invoke($script:JniEnv, $JString, $chars) }
}

function Initialize-ClipboardIds {
    if ($null -ne $script:ClipIds) { return }
    $activity = Get-JavaClass 'android/app/Activity'; $manager = Get-JavaClass 'android/content/ClipboardManager'
    $data = Get-JavaClass 'android/content/ClipData'; $item = Get-JavaClass 'android/content/ClipData$Item'
    $object = Get-JavaClass 'java/lang/Object'; $view = Get-JavaClass 'android/view/View'
    $haptic = Get-JavaClass 'android/view/HapticFeedbackConstants'; $window = Get-JavaClass 'android/view/Window'
    $script:ClipIds = @{
        GetSystemService = Get-JavaMethod $activity 'getSystemService' '(Ljava/lang/String;)Ljava/lang/Object;'
        SetPrimaryClip = Get-JavaMethod $manager 'setPrimaryClip' '(Landroid/content/ClipData;)V'
        GetPrimaryClip = Get-JavaMethod $manager 'getPrimaryClip' '()Landroid/content/ClipData;'
        DataClass = $data
        NewPlainText = Get-JavaMethod $data 'newPlainText' '(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;' -Static
        GetItemCount = Get-JavaMethod $data 'getItemCount' '()I'
        GetItemAt = Get-JavaMethod $data 'getItemAt' '(I)Landroid/content/ClipData$Item;'
        CoerceToText = Get-JavaMethod $item 'coerceToText' '(Landroid/content/Context;)Ljava/lang/CharSequence;'
        ToString = Get-JavaMethod $object 'toString' '()Ljava/lang/String;'
        GetWindow = Get-JavaMethod $activity 'getWindow' '()Landroid/view/Window;'
        GetDecorView = Get-JavaMethod $window 'getDecorView' '()Landroid/view/View;'
        PerformHaptic = Get-JavaMethod $view 'performHapticFeedback' '(I)Z'
        LongPress = $script:Jni.GetStaticIntField.Invoke($script:JniEnv, $haptic, (Get-JavaField $haptic 'LONG_PRESS' 'I' -Static))
    }
}

function Get-ActivityObject { $Interop::ReadIntPtr($script:Activity, 3 * [IntPtr]::Size) }   # ANativeActivity.clazz

function Get-ClipboardManager {
    Initialize-ClipboardIds
    $name = New-JavaString 'clipboard'
    try { Invoke-JavaCall $script:Jni.CallObjectMethodA (Get-ActivityObject) $script:ClipIds.GetSystemService @([IntPtr]$name) } finally { Remove-JavaLocalRef $name }
}

function Set-AndroidClipboard {
    <# Puts plain text on Android's clipboard (ClipData.newPlainText, ClipboardManager.setPrimaryClip). Main thread only. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
    $k = $script:ClipIds; $manager = Get-ClipboardManager; $k = $script:ClipIds
    $label = New-JavaString 'Pwsh'; $body = New-JavaString $Text
    try {
        $clip = Invoke-JavaCall $script:Jni.CallStaticObjectMethodA $k.DataClass $k.NewPlainText @([IntPtr]$label, [IntPtr]$body)
        Invoke-JavaCall $script:Jni.CallVoidMethodA $manager $k.SetPrimaryClip @([IntPtr]$clip)
        Remove-JavaLocalRef $clip
    }
    finally { Remove-JavaLocalRef $label; Remove-JavaLocalRef $body; Remove-JavaLocalRef $manager }
}

function Get-AndroidClipboard {
    <# The clipboard's first item as text, or an empty string. Android lets only the focused app read it. #>
    $manager = Get-ClipboardManager; $k = $script:ClipIds; $text = ''
    try {
        $clip = Invoke-JavaCall $script:Jni.CallObjectMethodA $manager $k.GetPrimaryClip
        if ($clip -ne [IntPtr]::Zero) {
            if ((Invoke-JavaCall $script:Jni.CallIntMethodA $clip $k.GetItemCount) -gt 0) {
                $item = Invoke-JavaCall $script:Jni.CallObjectMethodA $clip $k.GetItemAt @([int]0)
                $chars = Invoke-JavaCall $script:Jni.CallObjectMethodA $item $k.CoerceToText @([IntPtr](Get-ActivityObject))
                $str = Invoke-JavaCall $script:Jni.CallObjectMethodA $chars $k.ToString
                $text = ConvertFrom-JavaString $str
                Remove-JavaLocalRef $str; Remove-JavaLocalRef $chars; Remove-JavaLocalRef $item
            }
            Remove-JavaLocalRef $clip
        }
    }
    finally { Remove-JavaLocalRef $manager }
    $text
}

function Invoke-HapticFeedback {
    <# A system haptic on the window's decor view: a HapticFeedbackConstants field name, LONG_PRESS by default (REJECT, API 30, for hitting a limit). #>
    param([string] $Constant = 'LONG_PRESS')
    Initialize-ClipboardIds; $k = $script:ClipIds
    if (-not $script:HapticIds.ContainsKey($Constant)) {
        $h = Get-JavaClass 'android/view/HapticFeedbackConstants'
        $script:HapticIds[$Constant] = $script:Jni.GetStaticIntField.Invoke($script:JniEnv, $h, (Get-JavaField $h $Constant 'I' -Static))
    }
    $window = Invoke-JavaCall $script:Jni.CallObjectMethodA (Get-ActivityObject) $k.GetWindow
    $decor = Invoke-JavaCall $script:Jni.CallObjectMethodA $window $k.GetDecorView
    [void](Invoke-JavaCall $script:Jni.CallBooleanMethodA $decor $k.PerformHaptic @([int]$script:HapticIds[$Constant]))
    Remove-JavaLocalRef $decor; Remove-JavaLocalRef $window
}

function Register-LooperTimer {
    <#
        A one-shot timer on the main looper: a timerfd (CLOCK_MONOTONIC,
        TFD_NONBLOCK | TFD_CLOEXEC; bionic sys/timerfd.h) registered with
        ALooper_addFd, so the looper wakes us; nothing polls. Start-LooperTimer
        arms it, Stop-LooperTimer disarms it, and $OnElapsed runs on the main
        thread when it fires.
    #>
    param([Parameter(Mandatory)][scriptblock] $OnElapsed)
    $libc = @{
        Create = Get-NativeExport 'libc.so' 'timerfd_create' ([int]) @([int], [int])
        SetTime = Get-NativeExport 'libc.so' 'timerfd_settime' ([int]) @([int], [int], $I, $I)
        Read = Get-NativeExport 'libc.so' 'read' $I @([int], $I, $I)
    }
    $addFd = Get-NativeExport 'libandroid.so' 'ALooper_addFd' ([int]) @($I, [int], [int], [int], $I, $I)
    $script:Timer = @{ Libc = $libc; Fd = $libc.Create.Invoke(1, 0x800 -bor 0x80000); OnElapsed = $OnElapsed
                       Spec = $Interop::AllocHGlobal(4 * [IntPtr]::Size); Scratch = $Interop::AllocHGlobal(8) }
    if ($script:Timer.Fd -lt 0) { throw 'timerfd_create failed.' }
    $type = Get-NativeDelegateType ([int]) @([int], [int], [IntPtr])
    $onFd = { param([int] $Fd, [int] $Events, [IntPtr] $Data)
        try { [void]$script:Timer.Libc.Read.Invoke($Fd, $script:Timer.Scratch, [IntPtr]8); & $script:Timer.OnElapsed }
        catch { try { Write-AndroidLog ('AndroidCanvas timer: ' + $_.Exception.Message) 6 } catch { } }
        return 1 }
    $script:Timer.Callback = [Management.Automation.LanguagePrimitives]::ConvertTo($onFd, $type)   # rooted
    [void]$addFd.Invoke($script:Input.ForThread.Invoke(), $script:Timer.Fd, -2, 1, $Interop::GetFunctionPointerForDelegate($script:Timer.Callback), [IntPtr]::Zero)   # ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT
}

function Set-TimerSpec([long] $Milliseconds) {
    # struct itimerspec { timespec it_interval; timespec it_value; }, each timespec two longs (time_t, long).
    $p = [IntPtr]::Size; $sp = $script:Timer.Spec
    $Interop::WriteIntPtr($sp, 0, [IntPtr]::Zero); $Interop::WriteIntPtr($sp, $p, [IntPtr]::Zero)
    $Interop::WriteIntPtr($sp, 2 * $p, [IntPtr]([long][Math]::Floor($Milliseconds / 1000)))
    $Interop::WriteIntPtr($sp, 3 * $p, [IntPtr](($Milliseconds % 1000) * 1000000))
    [void]$script:Timer.Libc.SetTime.Invoke($script:Timer.Fd, 0, $sp, [IntPtr]::Zero)
}
function Start-LooperTimer { param([Parameter(Mandatory)][int] $Milliseconds) Set-TimerSpec $Milliseconds }
function Stop-LooperTimer { if ($null -ne $script:Timer) { Set-TimerSpec 0 } }

# --- 8. Audio output ---------------------------------------------------------------------

function Open-AudioOutput {
    <#
        Opens and starts one mono float AAudio output stream for short sounds
        (aaudio/AAudio.h, frameworks/av 402dbe88: AAUDIO_FORMAT_PCM_FLOAT 2,
        AAUDIO_PERFORMANCE_MODE_NONE 10, AAUDIO_USAGE_ASSISTANCE_SONIFICATION 13).
        The buffer capacity holds a whole sound, so Write-AudioOutput never
        waits and never stalls the main thread. Output needs no permission.
        Returns the stream's sample rate.
    #>
    param([int] $CapacityFrames = 16384)
    $aa = @{}
    foreach ($e in @(
        @('CreateBuilder', 'AAudio_createStreamBuilder', [int], @($I)),
        @('SetFormat', 'AAudioStreamBuilder_setFormat', [void], @($I, [int])),
        @('SetChannels', 'AAudioStreamBuilder_setChannelCount', [void], @($I, [int])),
        @('SetPerformance', 'AAudioStreamBuilder_setPerformanceMode', [void], @($I, [int])),
        @('SetUsage', 'AAudioStreamBuilder_setUsage', [void], @($I, [int])),
        @('SetCapacity', 'AAudioStreamBuilder_setBufferCapacityInFrames', [void], @($I, [int])),
        @('Open', 'AAudioStreamBuilder_openStream', [int], @($I, $I)),
        @('DeleteBuilder', 'AAudioStreamBuilder_delete', [int], @($I)),
        @('Start', 'AAudioStream_requestStart', [int], @($I)),
        @('Write', 'AAudioStream_write', [int], @($I, $I, [int], [long])),
        @('Rate', 'AAudioStream_getSampleRate', [int], @($I)))) {
        $aa[$e[0]] = Get-NativeExport 'libaaudio.so' $e[1] $e[2] ([type[]]$e[3])
    }
    $out = $Interop::AllocHGlobal([IntPtr]::Size)
    try {
        if ($aa.CreateBuilder.Invoke($out) -ne 0) { throw 'AAudio_createStreamBuilder failed.' }
        $b = $Interop::ReadIntPtr($out, 0)
        $aa.SetFormat.Invoke($b, 2); $aa.SetChannels.Invoke($b, 1); $aa.SetPerformance.Invoke($b, 10)
        $aa.SetUsage.Invoke($b, 13); $aa.SetCapacity.Invoke($b, $CapacityFrames)
        $rc = $aa.Open.Invoke($b, $out); [void]$aa.DeleteBuilder.Invoke($b)
        if ($rc -ne 0) { throw "AAudioStreamBuilder_openStream rc=$rc" }
        $stream = $Interop::ReadIntPtr($out, 0)
        if ($aa.Start.Invoke($stream) -ne 0) { throw 'AAudioStream_requestStart failed.' }
    }
    finally { $Interop::FreeHGlobal($out) }
    $script:Audio = @{ Fn = $aa; Stream = $stream; Rate = $aa.Rate.Invoke($stream) }
    $script:Audio.Rate
}

function Write-AudioOutput {
    <# Queues mono float samples without waiting; frames beyond the free buffer space are dropped. Returns the frames queued. #>
    param([Parameter(Mandatory)][float[]] $Samples)
    if ($null -eq $script:Audio) { return 0 }
    $handle = [Runtime.InteropServices.GCHandle]::Alloc($Samples, [Runtime.InteropServices.GCHandleType]::Pinned)
    try { $script:Audio.Fn.Write.Invoke($script:Audio.Stream, $handle.AddrOfPinnedObject(), $Samples.Length, [long]0) }
    finally { $handle.Free() }
}

# --- 9. Input ---------------------------------------------------------------------------

function Register-InputHandler {
    <#
        Attaches the activity's input queue to the main looper and calls $Handle
        for each event with a hashtable: Type ('key' or 'motion'), Action,
        X and Y (motion, pointer 0), KeyCode (key). $Handle returns $true when
        it consumed the event. Every event is finished, so input never stalls
        (an unread queue makes Android report the app as not responding).
    #>
    param([Parameter(Mandatory)][scriptblock] $Handle, [scriptblock] $AfterInput)
    $script:HandleInput = $Handle; $script:AfterInput = $AfterInput
    $looperType = Get-NativeDelegateType ([int]) @([int], [int], [IntPtr])
    $queueType = Get-NativeDelegateType ([void]) @([IntPtr], [IntPtr])
    $onEvents = {
        param([int] $Fd, [int] $Events, [IntPtr] $Data)
        # Nothing may escape to the native caller.
        try {
            $q = $script:InputQueue; $in = $script:Input; $drained = $false
            while ($in.GetEvent.Invoke($q, $script:EventSlot) -ge 0) {
                $ev = $Interop::ReadIntPtr($script:EventSlot, 0)
                if ($in.PreDispatch.Invoke($q, $ev) -ne 0) { continue }
                $handled = $false
                try {
                    $t = $in.EventType.Invoke($ev)
                    $info = if ($t -eq 2) {
                        # Action carries the pointer index in bits 8-15 (AMOTION_EVENT_ACTION_POINTER_INDEX_MASK).
                        $count = [int]$in.PointerCount.Invoke($ev)
                        $m = @{ Type = 'motion'; Action = $in.MotionAction.Invoke($ev) -band 0xff; Pointers = $count
                                X = $in.MotionX.Invoke($ev, [IntPtr]::Zero); Y = $in.MotionY.Invoke($ev, [IntPtr]::Zero) }
                        if ($count -ge 2) { $m.X2 = $in.MotionX.Invoke($ev, [IntPtr]1); $m.Y2 = $in.MotionY.Invoke($ev, [IntPtr]1) }
                        $m
                    }
                    else { @{ Type = 'key'; Action = $in.KeyAction.Invoke($ev); KeyCode = $in.KeyCode.Invoke($ev) } }
                    $handled = [bool](& $script:HandleInput $info)
                }
                catch { try { Write-AndroidLog ('AndroidCanvas input: ' + $_.Exception.Message + ' | at ' + (@(([string]$_.ScriptStackTrace) -split [char]10)[0..2] -join ' < ')) 6 } catch { } }
                $in.Finish.Invoke($q, $ev, [int]$handled)
                $drained = $true
            }
            # One call after the queue is empty: a burst of events coalesces into one redraw.
            if ($drained -and $null -ne $script:AfterInput) { & $script:AfterInput }
        }
        catch { try { Write-AndroidLog ('AndroidCanvas input queue: ' + $_.Exception.Message + ' | at ' + (@(([string]$_.ScriptStackTrace) -split [char]10)[0..2] -join ' < ')) 6 } catch { } }
        return 1   # keep receiving
    }
    $onCreated = { param([IntPtr] $Activity, [IntPtr] $Queue)
        try { $script:InputQueue = $Queue; $script:Input.Attach.Invoke($Queue, $script:Input.ForThread.Invoke(), 1, $script:InputPointer, [IntPtr]::Zero) }
        catch { try { Write-AndroidLog ('AndroidCanvas input attach: ' + $_.Exception.Message) 6 } catch { } } }
    $onDestroyed = { param([IntPtr] $Activity, [IntPtr] $Queue)
        try { $script:Input.Detach.Invoke($Queue); $script:InputQueue = [IntPtr]::Zero } catch { } }
    $looperCallback = [Management.Automation.LanguagePrimitives]::ConvertTo($onEvents, $looperType)
    $created = [Management.Automation.LanguagePrimitives]::ConvertTo($onCreated, $queueType)
    $destroyed = [Management.Automation.LanguagePrimitives]::ConvertTo($onDestroyed, $queueType)
    $script:InputCallbacks = @($looperCallback, $created, $destroyed)          # rooted for the process lifetime
    $script:InputPointer = $Interop::GetFunctionPointerForDelegate($looperCallback)
    $table = $Interop::ReadIntPtr($script:Activity, 0)
    $Interop::WriteIntPtr($table, 11 * [IntPtr]::Size, $Interop::GetFunctionPointerForDelegate($created))    # onInputQueueCreated
    $Interop::WriteIntPtr($table, 12 * [IntPtr]::Size, $Interop::GetFunctionPointerForDelegate($destroyed))  # onInputQueueDestroyed
}

Export-ModuleMember -Function New-NativeFunction, Get-NativeExport, Write-AndroidLog, ConvertTo-ArgbColor,
    Get-SystemBarInsets, Register-InputHandler, Request-WindowDraw, Set-AndroidClipboard, Get-AndroidClipboard,
    Invoke-HapticFeedback, Register-LooperTimer, Start-LooperTimer, Stop-LooperTimer, Open-AudioOutput, Write-AudioOutput,
    Initialize-AndroidCanvas, Get-CanvasSize, Get-TextCell, Clear-Canvas, Add-CanvasRect, Add-CanvasText,
    Invoke-CanvasFrame, Register-WindowDrawHandler
