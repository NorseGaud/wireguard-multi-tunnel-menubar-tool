set uninstallScriptPath to POSIX path of (path to resource "Uninstall.sh")
do shell script "/bin/sh " & quoted form of uninstallScriptPath with administrator privileges
