param(
  [ValidateRange(1, 1000)][int]$MaxNodes = 300,
  [ValidateRange(1, 24)][int]$MaxDepth = 12
)
# Read-only UI Automation snapshot. Never select/invoke controls or read text buffers.
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ContextTerminalWindows {
  delegate bool Callback(IntPtr window, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr data);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int length);
  public static IntPtr[] Read(int pid) {
    var result = new List<IntPtr>();
    int visited = 0;
    EnumWindows((window, data) => {
      if (++visited > 1024) return false;
      uint owner;
      GetWindowThreadProcessId(window, out owner);
      if (owner == pid && IsWindowVisible(window)) {
        var name = new StringBuilder(256);
        GetClassName(window, name, name.Capacity);
        if (name.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS") result.Add(window);
      }
      return true;
    }, IntPtr.Zero);
    if (visited > 1024) throw new InvalidOperationException("Window inventory limit reached");
    return result.ToArray();
  }
}
'@
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$windows = @()
foreach ($process in @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue)) {
  foreach ($handle in [ContextTerminalWindows]::Read($process.Id)) {
  $started = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
  $title = ''
  $tabs = @()
  $errors = @()
  $visited = 0
  $limited = $false
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
    $title = $root.Current.Name
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{element=$root; depth=0})
    while ($queue.Count -gt 0 -and $visited -lt $MaxNodes) {
      $entry = $queue.Dequeue()
      $element = $entry.element
      $visited++
      try {
        $current = $element.Current
        $type = $current.ControlType.ProgrammaticName
        if ($type -eq "ControlType.Document" -or $type -eq "ControlType.Text") { continue }
        if ($type -eq "ControlType.TabItem") {
          $selected = $null
          $pattern = $null
          if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
            $selected = $pattern.Current.IsSelected
          }
          $tabs += [pscustomobject]@{
            title=$current.Name; selected=$selected
            runtimeId=@($element.GetRuntimeId())
            x=$current.BoundingRectangle.X
          }
          continue
        }
        if ($entry.depth -ge $MaxDepth) { $limited = $true; continue }
        $child = $walker.GetFirstChild($element)
        while ($null -ne $child -and ($visited + $queue.Count) -lt $MaxNodes) {
          $queue.Enqueue([pscustomobject]@{element=$child; depth=($entry.depth + 1)})
          $child = $walker.GetNextSibling($child)
        }
        if ($null -ne $child) { $limited = $true }
      } catch {
        $errors += $_.Exception.Message
      }
    }
    if ($queue.Count -gt 0) { $limited = $true }
  } catch {
    $errors += $_.Exception.Message
  }
  $windows += [pscustomobject]@{
    pid=$process.Id; hwnd=$handle.ToInt64(); started=$started
    title=$title; visited=$visited; limited=$limited
    tabs=@($tabs | Sort-Object x); errors=$errors
  }
  }
}
ConvertTo-Json -InputObject @($windows) -Depth 6
