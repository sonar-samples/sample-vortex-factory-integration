# sonar analyze agentic --format json -> sorted "path:line [rule] message" lines
#
# --argjson ranges [{path,start,end}]  lines the candidate added or changed vs BASE_SHA
#                                      (end 2147483647 = whole file). Omit to treat every issue as new.
# --arg scope new|preexisting|all      which issues to print (default all)
#
# An issue is "new" when its text range overlaps a changed range (a range that spans changed and
# unchanged lines counts). An issue without a text range is "new" only in a wholly new file.
($ARGS.named.ranges // null) as $ranges
| ($ARGS.named.scope // "all") as $scope
| def is_new($path; $issue):
    if $ranges == null then true
    else
      ($issue.textRange.startLine // null) as $s
      | ($issue.textRange.endLine // $s) as $e
      | any($ranges[] | select(. as $r | $r.path == $path or ($path | endswith("/" + $r.path)));
          if $s == null then (.start == 1 and .end >= 2147483647)
          else (.start <= $e and .end >= $s) end)
    end;
[ .files[]? | .path as $p | .issues[]?
  | (.filePath // $p) as $f
  | select($scope == "all" or (is_new($f; .) == ($scope == "new")))
  | "\($f):\(.textRange.startLine // 0) [\(.rule)] \(.message | gsub("\\s+"; " "))" ]
| sort | .[]
