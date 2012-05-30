Option Explicit

' ts_block.vbs - Blocks IP addresses generating invalid Terminal Services logons.
' Copyright 2011 Wellbury LLC - See LICENSE for license information
'
' Release 20110831 - Adapted from sshd_block release 20100120
' Release 20120530 - No change from 20110831 code for ts_block script

' External executables required to be accessible from PATH:
'
' ROUTE.EXE          For black-hole routing blocked IP addresses in Windows 2003
' NETSH.EXE          For black-hole firewall rule creation on Windows Vista / 2008 / 7 / 2008 R2
' EVENTCREATE.EXE    For writing to the event log (if enabled)
'
' For support, please contact Evan Anderson at Wellbury LLC: 
'   EAnderson@wellbury.com, (866) 569-9799, ext 801

' Main
Dim objShell, objWMIService, objEventSink, blackHoleIPAddress, regexpSanitizeEventLog, regexpSanitizeIP
Dim dictIPLastSeenTime, dictIPBadLogons, dictUnblockTime, dictBlockImmediatelyUsers
Dim colOperatingSystem, intOSBuild, intBlackholeStyle
Dim intBlockDuration, intBlockAttempts, intBlockTimeout

' =====================( Configuration )=====================

' Set to 0 to disable debugging output
Const DEBUGGING = 0

' Set to 0 to disable event log reporting of blocks / unblocks
Const USE_EVENTLOG = 1
Const EVENTLOG_SOURCE = "ts_block"
Const EVENTLOG_TYPE_INFORMATION = "INFORMATION"
Const EVENTLOG_TYPE_ERROR = "ERROR"
Const EVENTLOG_ID_STARTED = 1
Const EVENTLOG_ID_ERROR_NO_BLACKHOLE_IP = 2
Const EVENTLOG_ID_ERROR_WIN_XP = 3
Const EVENTLOG_ID_BLOCK = 256
Const EVENTLOG_ID_UNBLOCK = 257

' Registry path for configuration
Const REG_CONFIG_PATH = "HKLM\Software\Policies\Wellbury LLC\ts_block\"

' Number of failed logons in time window before IP will be blocked
Const DEFAULT_BLOCK_ATTEMPTS = 5		' Attempts
Const REG_BLOCK_ATTEMPTS = "BlockAttempts"

' Expiration (in seconds) for IPs to be blocked
Const DEFAULT_BLOCK_DURATION = 300
Const REG_BLOCK_DURATION = "BlockDuration"

' Timeout for attempts before a new attempt is considered attempt #1
Const DEFAULT_BLOCK_TIMEOUT = 120	' in X seconds
Const REG_BLOCK_TIMEOUT = "BlockTimeout"

' Black hole IP address (if hard-specified)
Const REG_BLACKHOLE_IP = "BlackholeIP"

' Usernames that attempted logons for result in immediate blocking
Set dictBlockImmediatelyUsers = CreateObject("Scripting.Dictionary")
dictBlockImmediatelyUsers.Add "administrator", 1
dictBlockImmediatelyUsers.Add "root", 1
dictBlockImmediatelyUsers.Add "guest", 1

' ===================( End Configuration )===================

Const TS_BLOCK_VERSION = "20110831"
Const BLACKHOLE_ROUTE = 1		' Blackhole packets via routing table
Const BLACKHOLE_FIREWALL = 2	' Blackhole packets via firewall

' =====================( Stress Testing )====================

' Set to 1 to perform stress testing
Const TESTING = 0

' Number of "bogus" blocks to load
Const TESTING_IP_ADDRESSES = 10000

' Minimum and maximum milliseconds between adding "bogus" IPs to the block list during testing
Const TESTING_IP_MIN_LATENCY = 10
Const TESTING_IP_MAX_LATENCY = 50

If TESTING Then 
	Dim testLatency, cumulativeLatency, testLoop, maxBlocked, blockedAddresses
	Randomize
End If

' ===================( End Stress Testing )==================

Set dictIPLastSeenTime = CreateObject("Scripting.Dictionary")
Set dictIPBadLogons  = CreateObject("Scripting.Dictionary")
Set dictUnblockTime = CreateObject("Scripting.Dictionary")
Set objShell = CreateObject("WScript.Shell")

Set regexpSanitizeEventLog = new Regexp
regexpSanitizeEventLog.Global = True
regexpSanitizeEventLog.Pattern = "[^0-9a-zA-Z._ /:\-]"

Set regexpSanitizeIP = new Regexp
regexpSanitizeIP.Global = True
regexpSanitizeIP.Pattern = "[^0-9.]"

' Get OS build number
Set objWMIService = GetObject("winmgmts:{(security)}!root/cimv2")
Set colOperatingSystem = objWMIService.ExecQuery("SELECT BuildNumber FROM Win32_OperatingSystem")

For Each intOSBuild in colOperatingSystem
	' Windows OS versions with the "Advanced Firewall" functionality have build numbers greater than 4000
	If intOSBuild.BuildNumber < 4000 Then intBlackholeStyle = BLACKHOLE_ROUTE Else intBlackholeStyle = BLACKHOLE_FIREWALL

	If intOSBuild.BuildNumber = 2600 Then
		LogEvent EVENTLOG_ID_ERROR_WIN_XP, EVENTLOG_TYPE_ERROR, "Fatal Error - Windows XP does not provide an IP address to black-hole in failure audit event log entries."
		WScript.Quit EVENTLOG_ID_ERROR_WIN_XP
	End If
	
	If DEBUGGING Then WScript.Echo "intBlackHoleStyle = " & intBlackHoleStyle 
Next ' intOSBuild

' Read configuration from the registry, if present, in a really simplsitic way
On Error Resume Next ' Noooo!!!
intBlockDuration = DEFAULT_BLOCK_DURATION
If CInt(objShell.RegRead(REG_CONFIG_PATH & REG_BLOCK_DURATION)) > 0 Then intBlockDuration = CInt(objShell.RegRead(REG_CONFIG_PATH & REG_BLOCK_DURATION))

intBlockAttempts = DEFAULT_BLOCK_ATTEMPTS
If CInt(objShell.RegRead(REG_CONFIG_PATH & REG_BLOCK_ATTEMPTS)) > 0 Then intBlockAttempts = CInt(objShell.RegRead(REG_CONFIG_PATH & REG_BLOCK_ATTEMPTS))

intBlockTimeout = DEFAULT_BLOCK_TIMEOUT
If CInt(objShell.RegRead(REG_CONFIG_PATH & REG_BLOCK_TIMEOUT)) > 0 Then intBlockTimeout = CInt(objShell.RegRead(REG_CONFIG_PATH & REG_BLOCK_TIMEOUT))

If objShell.RegRead(REG_CONFIG_PATH & REG_BLACKHOLE_IP) <> "" Then
	blackHoleIPAddress = regexpSanitizeIP.Replace(objShell.RegRead(REG_CONFIG_PATH & REG_BLACKHOLE_IP), "")
Else
	blackHoleIPAddress = ""
End If

On Error Goto 0

' Only obtain a blackhole adapter address on versions of Windows where it is required
If (intBlackholeStyle = BLACKHOLE_ROUTE) and (blackHoleIPAddress = "") Then
	blackHoleIPAddress = GetBlackholeIP()
	If IsNull(blackHoleIPAddress) Then
		LogEvent EVENTLOG_ID_ERROR_NO_BLACKHOLE_IP, EVENTLOG_TYPE_ERROR, "Fatal Error - Could not obtain an IP address for an interface with no default gateway specified."
		WScript.Quit EVENTLOG_ID_ERROR_NO_BLACKHOLE_IP
	End If
End If

If DEBUGGING Then LogEvent EVENTLOG_ID_STARTED, EVENTLOG_TYPE_INFORMATION, "Block Duration: " & intBlockDuration
If DEBUGGING Then LogEvent EVENTLOG_ID_STARTED, EVENTLOG_TYPE_INFORMATION, "Block Attempts: " & intBlockAttempts
If DEBUGGING Then LogEvent EVENTLOG_ID_STARTED, EVENTLOG_TYPE_INFORMATION, "Block Timeout: " & intBlockTimeout
If DEBUGGING Then LogEvent EVENTLOG_ID_STARTED, EVENTLOG_TYPE_INFORMATION, "Blackhole IP: " &  blackHoleIPAddress

' Create event sink to catch security events
Set objEventSink = WScript.CreateObject("WbemScripting.SWbemSink", "eventSink_")
objWMIService.ExecNotificationQueryAsync objEventSink, "SELECT * FROM __InstanceCreationEvent WHERE TargetInstance ISA 'Win32_NTLogEvent' AND TargetInstance.Logfile = 'Security' AND TargetInstance.EventType = 5 AND (TargetInstance.EventIdentifier = 529 OR TargetInstance.EventIdentifier = 4625) AND (TargetInstance.SourceName = 'Security' OR TargetInstance.SourceName = 'Microsoft-Windows-Security-Auditing')"

LogEvent EVENTLOG_ID_STARTED, EVENTLOG_TYPE_INFORMATION, EVENTLOG_SOURCE & " (version " & TS_BLOCK_VERSION & ") started."

If TESTING Then
	If DEBUGGING Then WScript.Echo "Stress test loop"

	For testLoop = 1 to TESTING_IP_ADDRESSES 
		testLatency = Int(Rnd() * (TESTING_IP_MAX_LATENCY - TESTING_IP_MIN_LATENCY)) + TESTING_IP_MIN_LATENCY

		WScript.Sleep(testLatency)
		Block(CStr(Int(Rnd * 256)) & "." & CStr(Int(Rnd * 256)) & "." & CStr(Int(Rnd * 256)) & "." & CStr(Int(Rnd * 256)))
		blockedAddresses = blockedAddresses + 1

		' Try to ExpireBlocks no more often than once every 1000ms
		cumulativeLatency = cumulativeLatency + testLatency
		If cumulativeLatency >= 250 Then
			if blockedAddresses > maxBlocked Then maxBlocked = blockedAddresses
			cumulativeLatency = 0
			ExpireBlocks
		End If
	Next ' testLoop

	' Drain the queue
	While dictUnblockTime.Count > 0
		WScript.Sleep(250)
		ExpireBlocks
	Wend

	WScript.Echo "Stress test completed. " & TESTING_IP_ADDRESSES & " tested with a maximum of " & maxBlocked & " addresses blocked at once."

	' Loop until killed
	While (True)
		WScript.Sleep(250)
	Wend

Else

	If DEBUGGING Then WScript.Echo "Entering normal operation busy-wait loop."

	' Loop sleeping for 250ms, expiring blocks
	While (True)
		WScript.Sleep(250)
		ExpireBlocks
	Wend

End If


Sub Block(IP)
	' Block an IP address and set the time for the block expiration
	Dim strRunCommand
	Dim intRemoveBlockTime

	' Block an IP address (either by black-hole routing it or adding a firewall rule)
	If (TESTING <> 1) Then 
		If intBlackholeStyle = BLACKHOLE_ROUTE Then strRunCommand = "route add " & IP & " mask 255.255.255.255 " & blackHoleIPAddress 
		If intBlackholeStyle = BLACKHOLE_FIREWALL Then strRunCommand = "netsh advfirewall firewall add rule name=""Blackhole " & IP & """ dir=in protocol=any action=block remoteip=" & IP 

		If DEBUGGING Then WScript.Echo "Executing " & strRunCommand
		objShell.Run strRunCommand
	End If

	' Calculate time to remove block and add to dictUnblockTime
	intRemoveBlockTime = (Date + Time) + (intBlockDuration / (24 * 60 * 60))

	If NOT dictUnblockTime.Exists(intRemoveBlockTime) Then
		Set dictUnblockTime.Item(intRemoveBlockTime) = CreateObject("Scripting.Dictionary")
	End If
	If NOT dictUnblockTime.Item(intRemoveBlockTime).Exists(IP) Then dictUnblockTime.Item(intRemoveBlockTime).Add IP, 1

	LogEvent EVENTLOG_ID_BLOCK, EVENTLOG_TYPE_INFORMATION, "Blocked " & IP & " until " & intRemoveBlockTime
End Sub

Sub Unblock(IP)
	' Unblock an IP address
	Dim strRunCommand

	If (TESTING <> 1) Then 
		If intBlackholeStyle = BLACKHOLE_ROUTE Then strRunCommand = "route delete " & IP & " mask 255.255.255.255 " & blackHoleIPAddress  
		If intBlackholeStyle = BLACKHOLE_FIREWALL Then strRunCommand = "netsh advfirewall firewall delete rule name=""Blackhole " & IP & """"

		If DEBUGGING Then WScript.Echo "Executing " & strRunCommand
		objShell.Run strRunCommand
	End If

	LogEvent EVENTLOG_ID_UNBLOCK, EVENTLOG_TYPE_INFORMATION, "Unblocked " & IP
End Sub

Sub LogFailedLogonAttempt(IP)
	' Log failed logon attempts and, if necessary, block the IP address

	' Have we already seen this IP address before?
	If dictIPLastSeenTime.Exists(IP) Then

		' Be sure that prior attempts, if they are older than intBlockTimeout, don't count it against the IP
		If (dictIPLastSeenTime.Item(IP) + (intBlockTimeout / (24 * 60 * 60))) <= (Date + Time) Then
			If dictIPBadLogons.Exists(IP) Then dictIPBadLogons.Remove(IP)
		End If

		dictIPLastSeenTime.Item(IP) = (Date + Time)
	Else
		dictIPLastSeenTime.Add IP, (Date + Time)
	End If

	' Does this IP address already have a history of bad logons?
	If dictIPBadLogons.Exists(IP) Then
		dictIPBadLogons.Item(IP) = dictIPBadLogons.Item(IP) + 1
	Else
		dictIPBadLogons.Add IP, 1
	End If

	If DEBUGGING Then WScript.Echo "Logging bad attempt from " & IP & ", attempt # " & dictIPBadLogons.Item(IP)

	' Should we block this IP address?
	If dictIPBadLogons.Item(IP) = intBlockAttempts Then Block(IP)
End Sub

Sub ExpireBlocks()
	Dim unblockTime, ipAddress

	For Each unblockTime in dictUnblockTime.Keys

		If unblockTime <= (Date + Time) Then 
			For Each ipAddress in dictUnblockTime.Item(unblockTime)
				Unblock(ipAddress)
				If TESTING Then blockedAddresses = blockedAddresses - 1
			Next ' ipAddress

			dictUnblockTime.Remove unblockTime
		End If
	Next 'ipAddress
End Sub

' Should an invalid logon from specified user result in an immediate block?
Function BlockImmediate(user)
	Dim userToBlock

	For Each userToBlock in dictBlockImmediatelyUsers.Keys
		If UCase(user) = UCase(userToBlock) Then 
			BlockImmediate = True
			Exit Function
		End If
	Next 'userToBlock

	BlockImmediate = False
End Function

' Fires each time new security events are generated
Sub eventSink_OnObjectReady(objEvent, objWbemAsyncContext)
	Dim arrEventMessage, arrInvalidLogonText
	Dim IP, user

	' Differentiate W2K3 and W2K8+
	If objEvent.TargetInstance.SourceName = "Microsoft-Windows-Security-Auditing" Then
		user = objEvent.TargetInstance.InsertionStrings(5)
		IP = objEvent.TargetInstance.InsertionStrings(19)
	Else
		' Assume W2K3
		user = objEvent.TargetInstance.InsertionStrings(0)
		IP = objEvent.TargetInstance.InsertionStrings(11)
	End If
	
	' Make sure only characters allowed in IP addresses are passed to external commands
	IP = regexpSanitizeIP.Replace(IP, "")

	' If the event didn't generate both a username and IP address then do nothing
	If (IP <> "") AND (user <> "") Then
		If BlockImmediate(user) Then Block(IP) Else LogFailedLogonAttempt(IP)
	End If
End Sub

Function GetBlackholeIP()
	' Sift through the NICs on the machine to locate a NIC's IP to use to blackhole offending hosts.
	' Look for a NIC with no default gateway set and an IP address assigned. Return NULL if we can't
	' find one.

	Dim objNICs, objNICConfig
	Set objNICs = GetObject("winmgmts:\\.\root\cimv2").ExecQuery("SELECT * FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled = TRUE")

	' Scan for a NIC with no default gateway set and IP not 0.0.0.0
	For Each objNICConfig in objNICs
		If IsNull(objNICConfig.DefaultIPGateway) and (objNICConfig.IPAddress(0) <> "0.0.0.0") Then 
			If DEBUGGING Then WScript.Echo "Decided on black-hole IP address " & objNICConfig.IPAddress(0) & ", interface " & objNICConfig.Description
			GetBlackholeIP = objNICConfig.IPAddress(0)
			Exit Function
		End If
	Next

	' Couldn't find anything, return NULL to let caller know we failed
	GetBlackHoleIP = NULL
End Function

Sub LogEvent(ID, EventType, Message)
	' Log an event to the Windows event log

	' Sanitize input string
	Message = regexpSanitizeEventLog.Replace(Message, "")

	If DEBUGGING Then WScript.Echo "Event Log - Event ID: " & ID & ", Type: " & EventType & " - " & Message
	
	' Don't hit the event log during testing
	If TESTING Then Exit Sub

	If USE_EVENTLOG Then objShell.Exec "EVENTCREATE /L APPLICATION /SO " & EVENTLOG_SOURCE & " /ID " & ID & " /T " & EventType & " /D """ & Message & """"
End Sub
