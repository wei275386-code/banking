"""Install one macOS bundle without registering temporary or backup copies."""
import contextlib
import fcntl
import plistlib
import subprocess
import time

if __package__:
    from .app_install_primitives import default_app_path, BUNDLE_ID, install_lock, swap_bundles, running_app_pids, stop_app
else:
    from app_install_primitives import default_app_path, BUNDLE_ID, install_lock, swap_bundles, running_app_pids, stop_app
if __package__:
    from .tool_locations import launch_services_tool
else:
    from tool_locations import launch_services_tool



def activate(app, project):
    subprocess.run([launch_services_tool(), '-f', str(app)], check=True, capture_output=True, timeout=15)
    subprocess.run(['/usr/bin/open', '-g', str(app)], check=True, capture_output=True, timeout=15)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        pids = running_app_pids(app)
        if len(pids) == 1:
            return
        if len(pids) > 1:
            raise RuntimeError('More than one installed App process is running')
        time.sleep(0.1)
    raise RuntimeError('Installed App did not start')


def install_staged(candidate, app, project, output, activation=None):
    production = app == default_app_path()
    activation = activation or activate
    if app.is_symlink() or (app.exists() and not app.is_dir()):
        raise ValueError('App destination must be a real directory')
    existed = app.exists()
    if existed:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        expected = BUNDLE_ID if production else plistlib.loads((candidate / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
        if info.get('CFBundleIdentifier') != expected:
            raise ValueError('Refusing to replace an App with a different bundle identifier')
    with contextlib.ExitStack() as guards:
        if production:
            # Import/review child processes hold this same flock. Wait for their work
            # to finish before updating, rather than interrupting a data write.
            guard = guards.enter_context((output / '.review-processor.lock').open('a'))
            try:
                fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError('An import or review is active; retry the update after it finishes') from error
            stop_app(app)
        if existed:
            swap_bundles(candidate, app)
        else:
            candidate.replace(app)
        try:
            if production:
                activation(app, project)
        except Exception:
            # The temporary directory holds the complete former bundle after swap.
            try:
                if production:
                    stop_app(app)
            finally:
                # Restore the previous installation even if the failed new App
                # refuses to quit. Never let temporary cleanup erase that copy.
                if existed:
                    swap_bundles(candidate, app)
                else:
                    app.replace(candidate)
            if existed and production:
                activation(app, project)
            raise
