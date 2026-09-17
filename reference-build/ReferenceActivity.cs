using Android.App;
using Android.OS;

namespace Terminal.ReferenceBuild;

[Activity(Label = "Terminal Reference Build", MainLauncher = true, Exported = true)]
public sealed class ReferenceActivity : Activity
{
    protected override void OnCreate(Bundle? state)
    {
        base.OnCreate(state);
    }
}
