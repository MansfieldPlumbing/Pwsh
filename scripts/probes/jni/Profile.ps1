# JNI probe: GetVersion, a static field, an instance call and a static call
# with a jvalue[] argument, through the function table in Jni.ps1.
$ErrorActionPreference = 'Stop'
. ([IO.Path]::Combine($PSScriptRoot, 'Jni.ps1'))
Complete-NativeImports
$version = (Get-Jni GetVersion ([int]) @([IntPtr])).Invoke($global:JniEnv)
Write-AndroidLog ('JNI GetVersion 0x{0:x8}' -f $version)
$build = Get-JClass 'android/os/Build$VERSION'
$sdkInt = $global:Jni.GetStaticIntField.Invoke($global:JniEnv, $build, (Get-JField $build 'SDK_INT' 'I' -Static)); Assert-NoJavaException 'SDK_INT'
$nativeSdk = $global:JniM::ReadInt32($global:JniActivity, 6 * [IntPtr]::Size)
Write-AndroidLog "JNI Build.VERSION.SDK_INT $sdkInt, activity->sdkVersion $nativeSdk"
$activityClass = $global:Jni.GetObjectClass.Invoke($global:JniEnv, $global:JniActivityObject); Assert-NoJavaException 'GetObjectClass'
$packageName = ConvertFrom-JString (Invoke-JniA $global:Jni.CallObjectMethodA $global:JniActivityObject (Get-JMethod $activityClass 'getPackageName' '()Ljava/lang/String;'))
Write-AndroidLog "JNI getPackageName $packageName"
$integer = Get-JClass 'java/lang/Integer'
$hex = ConvertFrom-JString (Invoke-JniA $global:Jni.CallStaticObjectMethodA $integer (Get-JMethod $integer 'toHexString' '(I)Ljava/lang/String;' -Static) @([int]0x50575348))
Write-AndroidLog "JNI Integer.toHexString(0x50575348) $hex"
$pass = $version -eq 0x00010006 -and $sdkInt -eq $nativeSdk -and $packageName -eq 'dev.mansfieldplumbing.pwsh' -and $hex -eq '50575348'
Write-AndroidLog $(if ($pass) { 'JNI PASS' } else { 'JNI FAIL' })
$global:Gate2d = if ($pass) { 0x4A4E4931 } else { 0x4A4E4930 }