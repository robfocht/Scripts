property volumeName : "USBSTORAGE"
property shareURL : "smb://EPSON%20WF-4830%20Series._smb._tcp.local/USBSTORAGE"
property srcFolderPosix : "/Volumes/USBSTORAGE/EPSCAN"
property dstFolderPosix : "/Users/rfocht/Documents/Scans"
property retainedSourceScanCount : 10
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
		set cleanupResult to my cleanupSourceFolder()
		set {cleanupDeletedCount, cleanupSkippedCount, cleanupFailureCount, cleanupDetails} to my splitCleanupResult(cleanupResult)
		set noImportMessage to "No scans to import."
		if cleanupDeletedCount > 0 then
			set noImportMessage to noImportMessage & " Source cleanup deleted: " & cleanupDeletedCount & "."
		end if
		if cleanupFailureCount > 0 then
			«event sysodlog» noImportMessage & " Source cleanup failed: " & cleanupFailureCount & "." & return & return & cleanupDetails given «class btns»:{"OK"}, «class dflt»:"OK"
		else
			«event sysonotf» noImportMessage given «class appr»:"Scans Import"
		end if
		openScansInFinder()
		return
	end if
	
	set ocrCount to 0
	set skippedCount to 0
	set failedSummaries to {}
	set metadataFailedSummaries to {}
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
				set searchablePathText to my createSearchablePdf(dstPathText)
				set ocrCount to ocrCount + 1
				try
					my preserveCreationDate(srcPathText, searchablePathText)
				on error metadataErrMsg number metadataErrNum
					set metadataName to «event sysoexec» "/usr/bin/basename " & quoted form of searchablePathText
					set end of metadataFailedSummaries to (metadataName & " (" & metadataErrNum & "): " & metadataErrMsg)
				end try
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
	set cleanupResult to my cleanupSourceFolder()
	set {cleanupDeletedCount, cleanupSkippedCount, cleanupFailureCount, cleanupDetails} to my splitCleanupResult(cleanupResult)
	
	set summaryMessage to "Imported " & movedCount & " file(s). Searchable PDFs created: " & ocrCount & "."
	if skippedCount > 0 then
		set summaryMessage to summaryMessage & " Non-PDF skipped: " & skippedCount & "."
	end if
	if cleanupDeletedCount > 0 then
		set summaryMessage to summaryMessage & " Source cleanup deleted: " & cleanupDeletedCount & "."
	end if
	if (count of metadataFailedSummaries) > 0 then
		set summaryMessage to summaryMessage & " Creation date preservation failed: " & (count of metadataFailedSummaries) & "."
	end if
	if cleanupFailureCount > 0 then
		set summaryMessage to summaryMessage & " Source cleanup failed: " & cleanupFailureCount & "."
	end if
	if (count of failedSummaries) > 0 then
		set summaryMessage to summaryMessage & " OCR failed: " & (count of failedSummaries) & "."
		set detailMessage to "OCR failures:" & return & (my joinList(failedSummaries, return))
		if (count of metadataFailedSummaries) > 0 then
			set detailMessage to detailMessage & return & return & "Creation date preservation failures:" & return & (my joinList(metadataFailedSummaries, return))
		end if
		if cleanupFailureCount > 0 then
			set detailMessage to detailMessage & return & return & "Source cleanup failures:" & return & cleanupDetails
		end if
		«event sysodlog» summaryMessage & return & return & detailMessage given «class btns»:{"OK"}, «class dflt»:"OK"
	else if (count of metadataFailedSummaries) > 0 then
		set detailMessage to "Searchable PDFs were created, but their creation dates could not be matched to the originals:" & return & return & (my joinList(metadataFailedSummaries, return))
		if cleanupFailureCount > 0 then
			set detailMessage to detailMessage & return & return & "Source cleanup failures:" & return & cleanupDetails
		end if
		«event sysodlog» summaryMessage & return & return & detailMessage given «class btns»:{"OK"}, «class dflt»:"OK"
	else if cleanupFailureCount > 0 then
		«event sysodlog» summaryMessage & return & return & "Source cleanup failures:" & return & cleanupDetails given «class btns»:{"OK"}, «class dflt»:"OK"
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
	file_name=$f
	base_name=${file_name%.*}
	searched_dst=" & quoted form of (dstFolderPosix & "/") & "\"${base_name}_srch.pdf\"
	searched_dst_upper=" & quoted form of (dstFolderPosix & "/") & "\"${base_name}_srch.PDF\"
	original_dst_lower=" & quoted form of (dstFolderPosix & "/") & "\"${base_name}.pdf\"
	original_dst_upper=" & quoted form of (dstFolderPosix & "/") & "\"${base_name}.PDF\"
	if [ -e \"$dst_path\" ] || [ -e \"$searched_dst\" ] || [ -e \"$searched_dst_upper\" ] || [ -e \"$original_dst_lower\" ] || [ -e \"$original_dst_upper\" ]; then
		continue
	fi
	if cp \"$f\" " & quoted form of dstFolderPosix & "/; then
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
	return outputPath
end createSearchablePdf

on preserveCreationDate(sourcePath, targetPath)
	set dateString to «event sysoexec» "sh -c " & quoted form of "
birth_epoch=$(/usr/bin/stat -f %B -- \"$1\")
if [ -z \"$birth_epoch\" ] || [ \"$birth_epoch\" -le 0 ]; then
	echo \"Source file has no usable creation date\" >&2
	exit 1
fi
/bin/date -r \"$birth_epoch\" '+%m/%d/%Y %H:%M:%S'
" & " sh " & quoted form of sourcePath
	«event sysoexec» "/usr/bin/SetFile -d " & quoted form of dateString & " " & quoted form of targetPath
end preserveCreationDate

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
printf '%s/%s_srch.pdf' \"$parent_path\" \"$base_name\"
" & " sh " & quoted form of inputPath
end searchedPdfPathFor

on moveFileToTrash(posixPath)
	set fileAlias to POSIX file posixPath as alias
	tell application "Finder.app"
		delete fileAlias
	end tell
end moveFileToTrash

on cleanupSourceFolder()
	try
		return «event sysoexec» "sh -c " & quoted form of "
src_dir=$1
dst_dir=$2
retain_count=$3
/usr/bin/find \"$src_dir\" -maxdepth 1 -type f -print | while IFS= read -r path; do
	birth_epoch=$(/usr/bin/stat -f %B -- \"$path\" 2>/dev/null || echo 0)
	modify_epoch=$(/usr/bin/stat -f %m -- \"$path\" 2>/dev/null || echo 0)
	sort_epoch=$birth_epoch
	if [ -z \"$sort_epoch\" ] || [ \"$sort_epoch\" -le 0 ]; then
		sort_epoch=$modify_epoch
	fi
	printf '%s	%s
' \"$sort_epoch\" \"$path\"
done | /usr/bin/sort -rn | /usr/bin/awk -v retain=\"$retain_count\" 'NR > retain { sub(/^[^\t]*\t/, \"\"); print }' | while IFS= read -r path; do
	file_name=${path##*/}
	base_name=${file_name%.*}
	dst_path=\"$dst_dir/$file_name\"
	searched_dst=\"$dst_dir/${base_name}_srch.pdf\"
	searched_dst_upper=\"$dst_dir/${base_name}_srch.PDF\"
	original_dst_lower=\"$dst_dir/${base_name}.pdf\"
	original_dst_upper=\"$dst_dir/${base_name}.PDF\"
	if [ ! -e \"$dst_path\" ] && [ ! -e \"$searched_dst\" ] && [ ! -e \"$searched_dst_upper\" ] && [ ! -e \"$original_dst_lower\" ] && [ ! -e \"$original_dst_upper\" ]; then
		printf 'SKIPPED	%s
' \"$path\"
		continue
	fi
	if /bin/rm -f -- \"$path\"; then
		printf 'DELETED	%s
' \"$path\"
	else
		printf 'FAILED	%s
' \"$path\"
	fi
done
" & " sh " & quoted form of srcFolderPosix & " " & quoted form of dstFolderPosix & " " & quoted form of (retainedSourceScanCount as text)
	on error errMsg number errNum
		return "FAILED	Source cleanup command (" & errNum & "): " & errMsg
	end try
end cleanupSourceFolder

on splitImportPair(pairText)
	set appleTextItemDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to tab
	set pairItems to text items of pairText
	set AppleScript's text item delimiters to appleTextItemDelimiters
	
	if (count of pairItems) is not 2 then error "Unexpected import record: " & pairText
	return pairItems
end splitImportPair

on splitCleanupResult(cleanupText)
	set deletedCount to 0
	set skippedCount to 0
	set failedCount to 0
	set detailLines to {}
	if cleanupText is not "" then
		repeat with cleanupLine in paragraphs of cleanupText
			set lineText to contents of cleanupLine
			if lineText starts with "DELETED" & tab then
				set deletedCount to deletedCount + 1
			else if lineText starts with "SKIPPED" & tab then
				set skippedCount to skippedCount + 1
				set end of detailLines to lineText
			else if lineText starts with "FAILED" & tab then
				set failedCount to failedCount + 1
				set end of detailLines to lineText
			end if
		end repeat
	end if
	return {deletedCount, skippedCount, failedCount, my joinList(detailLines, return)}
end splitCleanupResult

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
