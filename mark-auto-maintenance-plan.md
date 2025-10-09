# Mark Auto-Maintenance Implementation Plan

## Overview
Integrate automatic mark position updates with the autosave system to keep marks relevant as code changes.

## Core Components

### 1. File Change Detection
- Hook into `after-save-hook` to detect when files with marks are saved
- Only process files that actually contain marks (performance optimization)

### 2. Mark Relocation Algorithm
```
For each mark in the saved file:
1. Extract the preview content (stored line text)
2. Search entire file for exact matches
3. If multiple matches found, choose closest to original line number
4. If no matches found, mark for removal
5. Update mark position or remove mark
```

### 3. Core Functions to Implement

#### `my/update-marks-after-save()`
- Entry point: called on every file save
- Checks if current file contains any marks
- Calls relocation function if marks found

#### `my/get-marks-for-file(file-path)`
- Returns list of all marks for a specific file
- Efficient lookup in the marks hash table

#### `my/find-line-by-content(content, original-line)`
- Searches file for exact line content matches
- Returns closest match to original line number
- Returns nil if no matches found

#### `my/update-mark-position(mark-name, new-line)`
- Updates mark's line number and position
- Regenerates mark context at new position
- Updates last-visited timestamp

#### `my/remove-obsolete-mark(mark-name)`
- Removes mark from hash table
- Optionally notifies user about removal
- Updates markdown file

### 4. Smart Line Selection Logic
When multiple matches found:
```elisp
(defun closest-line-to-original (matches original-line)
  "Return line number closest to original position"
  (car (sort matches 
             (lambda (a b) 
               (< (abs (- a original-line))
                  (abs (- b original-line)))))))
```

### 5. Performance Optimizations
- Maintain file→marks lookup table for fast access
- Only search files that actually contain marks
- Cache file content during search to avoid multiple reads
- Batch updates and regenerate markdown once at the end

## Implementation Steps

### Phase 1: Basic Infrastructure
1. ✅ Create file change detection hook
2. ✅ Implement mark lookup by file path
3. ✅ Create line content search function
4. ✅ Add mark position update functionality

### Phase 2: Core Algorithm
1. ✅ Implement mark relocation logic
2. ✅ Add closest-line selection algorithm
3. ✅ Handle mark removal for missing content
4. ✅ Integrate with existing mark system

### Phase 3: Integration & Polish
1. ✅ Hook into after-save-hook
2. ✅ Update markdown regeneration
3. ✅ Add user notifications (optional)
4. ✅ Test with various scenarios

## Data Structures

### File-to-Marks Lookup (for performance)
```elisp
(defvar my/file-marks-cache (make-hash-table :test 'equal)
  "Cache mapping file paths to lists of mark names")
```

### Mark Update Results
```elisp
;; Track what happened during update
(defstruct mark-update-result
  updated-marks    ; list of (mark-name old-line new-line)
  removed-marks    ; list of mark-names
  unchanged-marks) ; list of mark-names
```

## User Experience

### Notification Strategy
- Silent by default (marks just work)
- Optional message showing update summary
- Warning for removed marks (user can undo)

### Configuration Options
```elisp
(defvar my/mark-auto-update-enabled t
  "Enable automatic mark position updates on file save")

(defvar my/mark-removal-notification t
  "Show notification when marks are removed")
```

## Edge Cases to Handle

1. **Multiple identical lines**: Choose closest to original
2. **No matches found**: Remove mark with optional notification
3. **Buffer not visiting file**: Skip update
4. **Very large files**: Limit search scope if needed
5. **Marks in temp/generated files**: Handle gracefully

## Testing Scenarios

1. **Simple case**: Line content unchanged, line number same
2. **Moved content**: Line moved up/down in file
3. **Deleted content**: Line removed entirely
4. **Duplicate content**: Multiple lines with same content
5. **File renamed**: Marks should become invalid
6. **Multiple marks per file**: All updated correctly

## Success Criteria

✅ Marks automatically stay synchronized with code changes
✅ Dead marks are removed automatically
✅ Performance impact is minimal
✅ User experience is seamless (marks "just work")
✅ Integration with existing markdown system works
✅ No data loss or corruption of mark system

## Future Enhancements (Optional)

- Smart context-aware matching (function boundaries, etc.)
- Mark migration when files are renamed
- Backup/restore for accidentally removed marks
- Statistics on mark stability over time
- Integration with version control systems