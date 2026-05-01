property volumeName : "UtilPi Files"
property shareURL : "smb://utilpi/UtilPi%20Files"
property srcFolderPosix : "/Volumes/UtilPi Files/scans"
property dstFolderPosix : "/Users/rfocht/Documents/Scans"
property shellPath : "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

on run
	«event sysoexec» "mkdir -p " & quoted form of dstFolderPosix
	
	if not isVolumeMounted(volumeName) then
		try
			«event aevtmvol» shareURL
		on error errMsg number errNum
			«event sysodlog» "Could not mount " & volumeName & "." & return & return & errMsg given «class btns»:{"OK"}, «class dflt»:"OK"
			return
		end try
	end if
	
	if not pathExists(srcFolderPosix) then
		«event sysodlog» "Source folder not found:" & return & srcFolderPosix given «class btns»:{"OK"}, «class dflt»:"OK"
		return
	end if
	
	set importedPairs to importIncomingFiles()
	set movedCount to count of importedPairs
	
	if movedCount is 0 then
		«event sysonotf» "No scans to import." given «class appr»:"Scans Import"
		openScansInFinder()
		return
	end if
	
	set ocrCount to 0
	set skippedCount to 0
	set failedSummaries to {}
	set processedCount to 0
	set progress total steps to movedCount
	set progress completed steps to 0
	set progress description to "Creating searchable PDFs"
	set progress additional description to ""
	
	repeat with importedPair in importedPairs
		set processedCount to processedCount + 1
		set {srcPathText, dstPathText} to my splitImportPair(contents of importedPair)
		set progress additional description to "Working on " & («event sysoexec» "/usr/bin/basename " & quoted form of dstPathText)
		if my isPdfFile(dstPathText) then
			try
				my createSearchablePdf(dstPathText)
				my deleteSourceFile(srcPathText)
				set ocrCount to ocrCount + 1
			on error errMsg number errNum
				set failedName to «event sysoexec» "/usr/bin/basename " & quoted form of dstPathText
				set end of failedSummaries to (failedName & " (" & errNum & "): " & errMsg)
			end try
		else
			set skippedCount to skippedCount + 1
		end if
		set progress completed steps to processedCount
	end repeat
	
	set progress additional description to ""
	
	set summaryMessage to "Imported " & movedCount & " file(s). Searchable PDFs created: " & ocrCount & "."
	if skippedCount > 0 then
		set summaryMessage to summaryMessage & " Non-PDF skipped: " & skippedCount & "."
	end if
	if (count of failedSummaries) > 0 then
		set summaryMessage to summaryMessage & " OCR failed: " & (count of failedSummaries) & "."
		«event sysodlog» summaryMessage & return & return & "Failures:" & return & (my joinList(failedSummaries, return)) given «class btns»:{"OK"}, «class dflt»:"OK"
	else
		«event sysonotf» summaryMessage given «class appr»:"Scans Import"
	end if
	
	openScansInFinder()
end run

on importIncomingFiles()
	try
		set movedOutput to «event sysoexec» "sh -c " & quoted form of ("
cd " & quoted form of srcFolderPosix & " || exit 0
for f in *; do
	[ -e \"$f\" ] || continue
	src_path=" & quoted form of (srcFolderPosix & "/") & "\"$f\"
	dst_path=" & quoted form of (dstFolderPosix & "/") & "\"$f\"
	if cp -n \"$f\" " & quoted form of dstFolderPosix & "/; then
		printf '%s	%s
' \"$src_path\" \"$dst_path\"
	fi
done
")
	on error errMsg number errNum
		«event sysodlog» "Import failed (" & errNum & "):" & return & errMsg given «class btns»:{"OK"}, «class dflt»:"OK"
		return {}
	end try
	
	if movedOutput is "" then return {}
	return paragraphs of movedOutput
end importIncomingFiles

on createSearchablePdf(inputPath)
	set resolvedOcrmypdfPath to my resolveOcrmypdfPath()
	if resolvedOcrmypdfPath is "" then error "ocrmypdf not found. Install it with: brew install ocrmypdf"
	
	set outputPath to searchedPdfPathFor(inputPath)
	set ocrCommand to "PATH=" & quoted form of shellPath & " " & quoted form of resolvedOcrmypdfPath & " --deskew --skip-text -- " & quoted form of inputPath & " " & quoted form of outputPath
	«event sysoexec» ocrCommand
	my moveFileToTrash(inputPath)
end createSearchablePdf

on resolveOcrmypdfPath()
	set lookupCommand to "PATH=" & quoted form of shellPath & " sh -c " & quoted form of "for candidate in /opt/homebrew/bin/ocrmypdf /usr/local/bin/ocrmypdf; do
	if [ -x \"$candidate\" ]; then
		printf '%s' \"$candidate\"
		exit 0
	fi
done
command -v ocrmypdf 2>/dev/null || true"
	return «event sysoexec» lookupCommand
end resolveOcrmypdfPath

on searchedPdfPathFor(inputPath)
	return «event sysoexec» "sh -c " & quoted form of "
input_path=$1
parent_path=$(dirname \"$input_path\")
file_name=$(basename \"$input_path\")
base_name=${file_name%.*}
extension=${file_name##*.}
if [ \"$base_name\" = \"$file_name\" ]; then
	extension=pdf
fi
printf '%s/%s_srch.%s' \"$parent_path\" \"$base_name\" \"$extension\"
" & " sh " & quoted form of inputPath
end searchedPdfPathFor

on moveFileToTrash(posixPath)
	set fileAlias to POSIX file posixPath as alias
	tell application "Finder.app"
		delete fileAlias
	end tell
end moveFileToTrash

on deleteSourceFile(posixPath)
	«event sysoexec» "rm -f " & quoted form of posixPath
end deleteSourceFile

on splitImportPair(pairText)
	set appleTextItemDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to tab
	set pairItems to text items of pairText
	set AppleScript's text item delimiters to appleTextItemDelimiters
	
	if (count of pairItems) is not 2 then error "Unexpected import record: " & pairText
	return pairItems
end splitImportPair

on isPdfFile(filePath)
	set lowerPath to «event sysoexec» "/bin/echo " & quoted form of filePath & " | /usr/bin/tr '[:upper:]' '[:lower:]'"
	return lowerPath ends with ".pdf"
end isPdfFile

on isVolumeMounted(vName)
	tell application "System Events"
		return (exists disk vName)
	end tell
end isVolumeMounted

on pathExists(p)
	try
		«event sysoexec» "test -e " & quoted form of p
		return true
	on error
		return false
	end try
end pathExists

on joinList(theList, delimiterText)
	set appleTextItemDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to delimiterText
	set joinedText to theList as text
	set AppleScript's text item delimiters to appleTextItemDelimiters
	return joinedText
end joinList

on openScansInFinder()
	set scansFolderAlias to POSIX file dstFolderPosix as alias
	
	tell application "Finder.app"
		activate
		set scansWindow to make new «class brow» given «class to  »:scansFolderAlias
		set «class pvew» of scansWindow to «constant ecvwclvw»
		set «class fvtg» of scansWindow to scansFolderAlias
	end tell
end openScansInFinder
