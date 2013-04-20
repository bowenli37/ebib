;;; ebib.el --- a BibTeX database manager

;; Copyright (c) 2003-2013 Joost Kremers
;; All rights reserved.

;; Author: Joost Kremers <joostkremers@fastmail.fm>
;; Maintainer: Joost Kremers <joostkremers@fastmail.fm>
;; Created: 2003
;; Version: ==VERSION==
;; Keywords: text bibtex

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;;
;; 1. Redistributions of source code must retain the above copyright
;;    notice, this list of conditions and the following disclaimer.
;; 2. Redistributions in binary form must reproduce the above copyright
;;    notice, this list of conditions and the following disclaimer in the
;;    documentation and/or other materials provided with the distribution.
;; 3. The name of the author may not be used to endorse or promote products
;;    derived from this software without specific prior written permission.
;;
;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
;; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
;; OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
;; IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
;; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
;; NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES ; LOSS OF USE,
;; DATA, OR PROFITS ; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
;; THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;;; Commentary:

;; Ebib is a BibTeX database manager that runs in GNU Emacs. With Ebib, you
;; can create and manage .bib-files, all within Emacs. It supports @string
;; and @preamble definitions, multiline field values, searching, and
;; integration with Emacs' (La)TeX mode.

;; See the Ebib manual for usage and installation instructions.

;; The latest release version of Ebib, contact information and mailing list
;; can be found at <http://ebib.sourceforge.net>. Development sources can be
;; found at <https://github.com/joostkremers/ebib>.

;; Code:

;; TODO

;; - write a function ebib-redisplay-all that updates the index and entry
;;   buffers and then makes the index buffer active. (or possibly restores
;;   the active buffer, but I'm pretty sure it'll only need to be called
;;   from the index buffer.) The point is that ebib-fill-index-buffer now
;;   changes ebib-cur-keys-list, which means we cannot call
;;   ebib-fill-entry-buffer *before* ebib-fill-index-buffer to make the
;;   latter active, as we've been doing. Alternatively, we should swap the
;;   calls to ebib-fill-entry-buffer and ebib-fill-index-buffer.

;; - rewrite the export functions

;; TODO REMARKS
;;
;; Only the ebib-db-* functions should take the database as an argument.
;; Any other setter/getter functions should specialise on ebib-cur-db only.
;; For example, ebib-set-modified does more than just change the modified
;; status of the database, it also (un)sets the modified flag of the index
;; buffer. Since ebib-db-set-modified cannot do that, it makes sense to
;; have the additional setter function ebib-set-modified. But it should be
;; specialised on ebib-cur-db. Same for ebib-store-{entry|string}, etc.
;;
;; Possible exceptions are ebib-save-database (which is used in
;; ebib-save-all-databases) and ebib-format-{database|entry|field|strings}
;; (which are used in ebib-save-database).


(eval-when-compile
  (if (string< (format "%d.%d" emacs-major-version emacs-minor-version) "24.3")
      (progn
        (require 'cl)
        (defalias 'cl-remove 'remove*)
        (defalias 'cl-caddr 'caddr)
        (defalias 'cl-multiple-value-bind 'multiple-value-bind)
        (defalias 'cl-macrolet 'macrolet))
    (require 'cl-lib)))
(require 'easymenu)
(require 'bibtex)
(require 'ebib-db)

;; Make sure we can call bibtex-generate-autokey.
(declare-function bibtex-generate-autokey "bibtex" nil)
(unless (< emacs-major-version 24)
  (bibtex-set-dialect)) ; This initializes some stuff that is needed for bibtex-generate-autokey.

;;;;;;;;;;;;;;;;;;;;;;
;; Global Variables ;;
;;;;;;;;;;;;;;;;;;;;;;

;; User Customisation

(defgroup ebib nil "Ebib: a BibTeX database manager" :group 'tex)

(defcustom ebib-default-type "article"
  "The default type for a newly created BibTeX entry."
  :group 'ebib
  :type 'string)

(defcustom ebib-preload-bib-files nil
  "List of .bib files to load automatically when Ebib starts."
  :group 'ebib
  :type '(repeat (file :must-match t)))

(defcustom ebib-preload-bib-search-dirs '("~")
  "List of directories to search for .bib files to be preloaded."
  :group 'ebib
  :type '(repeat :tag "Search directories for .bib files" (string :tag "Directory")))

(defcustom ebib-create-backups t
  "If set, create a backup file of a .bib file when it is first saved."
  :group 'ebib
   :type '(choice (const :tag "Create backups" t)
                 (const :tag "Do not create backups" nil)))

(defcustom ebib-additional-fields '("crossref"
                                    "url"
                                    "annote"
                                    "abstract"
                                    "keywords"
                                    "file"
                                    "timestamp"
                                    "doi")
  "List of the additional fields."
  :group 'ebib
  :type '(repeat (string :tag "Field")))

(defcustom ebib-hidden-fields '("timestamp")
  "List of field that are not shown by default."
  :group 'ebib
  :type '(repeat (string :tag "Field")))

(defcustom ebib-layout 'full
  "Ebib window layout.
Full width: Ebib occupies the entire Emacs frame.
Custom width: Ebib occupies the right side of the Emacs frame,
with the left side free for another window."
  :group 'ebib
  :type '(choice (const :tag "Full width" full)
                 (const :tag "Custom width" custom)))

(defcustom ebib-width 80
  "Width of the Ebib windows.
Only takes effect if EBIB-LAYOUT is set to CUSTOM."
  :group 'ebib
  :type 'integer)

(defcustom ebib-index-window-size 10
  "The number of lines used for the index buffer window."
  :group 'ebib
  :type 'integer)

(defcustom ebib-index-display-fields nil
  "List of the fields to display in the index buffer."
  :group 'ebib
  :type '(repeat (string :tag "Index Field")))

(defcustom ebib-uniquify-keys nil
  "Create unique keys.
If set, Ebib will not complain about duplicate keys but will
instead create a unique key by adding an identifier to it.
Identifiers are created from consecutive letters of the
alphabet, starting with `b'."
  :group 'ebib
  :type 'boolean)

(defcustom ebib-autogenerate-keys nil
  "If set, Ebib generates key automatically.
Uses the function BIBTEX-GENERATE-AUTOKEY, see there for
customization options."
  :group 'ebib
  :type 'boolean)

(defcustom ebib-citation-commands '((any
                                     (("cite" "\\cite%<[%A]%>{%K}")))
                                    (org-mode
                                     (("ebib" "[[ebib:%K][%A]]")))
                                    (markdown-mode
                                     (("text" "@%K%< [%A]%>")
                                      ("paren" "[%(%<%A %>@%K%<, %A%>%; )]")
                                      ("year" "[-@%K%< %A%>]"))))
  "A list of format strings to insert a citation into a buffer.
These are used with EBIB-INSERT-BIBTEX-KEY and
EBIB-PUSH-BIBTEX-KEY."
  :group 'ebib
  :type '(repeat (list :tag "Mode" (symbol :tag "Mode name")
                       (repeat (list :tag "Citation command"
                                     (string :tag "Identifier")
                                     (string :tag "Format string"))))))

(defcustom ebib-multiline-major-mode 'text-mode
  "The major mode of the multiline edit buffer."
  :group 'ebib
  :type '(function :tag "Mode function"))

(defcustom ebib-sort-order nil
  "The fields on which the BibTeX entries are to be sorted in the .bib file.
Sorting is done on different sort levels, and each sort level contains one
or more sort keys."
  :group 'ebib
  :type '(repeat (repeat :tag "Sort level" (string :tag "Sort field"))))

(defcustom ebib-save-xrefs-first nil
  "If true, entries with a crossref field will be saved first in the .bib-file.
Setting this option has unpredictable results for the sort order
of entries, so it is not compatible with setting the Sort Order option."
  :group 'ebib
  :type 'boolean)

(defcustom ebib-use-timestamp nil
  "If true, new entries will get a time stamp.
The time stamp will be stored in a field \"timestamp\" that can
be made visible with the command \\[ebib-toggle-hidden] in the
index buffer."
  :group 'ebib
  :type 'boolean)

(defcustom ebib-timestamp-format "%a %b %e %T %Y"
  "Format of the time string used in the timestamp.
The format is passed unmodified to FORMAT-TIME-STRING, see the
documentation of that function for details."
  :group 'ebib
  :type 'string)

(defcustom ebib-standard-url-field "url"
  "Standard field to store urls in.
In the index buffer, the command ebib-browse-url can be used to
send a url to a browser. This option sets the field from which
this command extracts the url."
  :group 'ebib
  :type 'string)

(defcustom ebib-url-regexp "\\\\url{\\(.*\\)}\\|https?://[^ '<>\"\n\t\f]+"
  "Regular expression to extract urls from a field."
  :group 'ebib
  :type 'string)

(defcustom ebib-browser-command ""
  "Command to call the browser with.
GNU/Emacs has a function call-browser, which is used if this
option is unset."
  :group 'ebib
  :type '(string :tag "Browser command"))

(defcustom ebib-standard-doi-field "doi"
  "Standard field to store a DOI (digital object identifier) in.
In the index buffer, the command ebib-browse-doi can be used to
send a suitable url to a browser. This option sets the field from
which this command extracts the doi."
  :group 'ebib
  :type 'string)

(defcustom ebib-doi-url "http://dx.doi.org/%s"
  "URL for opening a doi.
This value must contain one `%s', which will be replaced with the doi."
  :group 'ebib
  :type 'string)

(defcustom ebib-standard-file-field "file"
  "Standard field to store filenames in.
In the index buffer, the command ebib-view-file can be used to
view a file externally. This option sets the field from which
this command extracts the filename."
  :group 'ebib
  :type 'string)

(defcustom ebib-file-associations '(("pdf" . "xpdf")
                                    ("ps" . "gv"))
  "List of file associations.
Lists file extensions together with external programs to handle
files with those extensions. If the external program is left
blank, Ebib tries to handle the file internally in
Emacs (e.g. with doc-view-mode)."
  :group 'ebib
  :type '(repeat (cons :tag "File association"
                       (string :tag "Extension") (string :tag "Command"))))

(defcustom ebib-file-regexp "[^?|\\:*<>\" \n\t\f]+"
  "Regular expression to extract filenames from a field."
  :group 'ebib
  :type 'string)

(defcustom ebib-file-search-dirs '("~")
  "List of directories to search when viewing external files."
  :group 'ebib
  :type '(repeat :tag "Search directories" (string :tag "Directory")))

(defcustom ebib-print-preamble nil
  "Preamble used for the LaTeX file for printing the database.
Each string is added to the preamble on a separate line."
  :group 'ebib
  :type '(repeat (string :tag "Add to preamble")))

(defcustom ebib-print-newpage nil
  "If set, each entry is printed on a separate page."
  :group 'ebib
  :type 'boolean)

(defcustom ebib-print-multiline nil
  "If set, multiline fields are included when printing the database."
  :group 'ebib
  :type 'boolean)

(defcustom ebib-latex-preamble '("\\bibliographystyle{plain}")
  "Preamble used for the LaTeX file for BibTeXing the database.
Each string is added to the preamble on a separate line."
  :group 'ebib
  :type '(repeat (string :tag "Add to preamble")))

(defcustom ebib-print-tempfile ""
  "Temporary file for use with EBIB-PRINT-DATABASE and EBIB-LATEX-DATABASE."
  :group 'ebib
  :type '(file))

(defcustom ebib-allow-identical-fields nil
  "If set, Ebib handles multiple occurrences of a field gracefully."
  :group 'ebib
  :type 'boolean)

(defcustom ebib-keywords-list nil
  "General list of keywords."
  :group 'ebib
  :type '(repeat (string :tag "Keyword")))

(defcustom ebib-keywords-file ""
  "Single or generic file name for storing keywords.
Keywords can be stored in a single keywords file, which is used
for all .bib files, or in per-directory keywords files located in
the same directories as the .bib files.  In the latter case, the
keywords file should specify just the generic name and no path."
  :group 'ebib
  :type '(choice (file :tag "Use single keywords file")
                 (string :value "ebib-keywords.txt" :tag "Use per-directory keywords file")))

(defcustom ebib-keywords-file-save-on-exit 'ask
  "Action to take when new keywords are added during a session.
This option only makes sense if `ebib-keywords-file' is set."
  :group 'ebib
  :type '(choice (const :tag "Always save on exit" always)
                 (const :tag "Do not save on exit" nil)
                 (const :tag "Ask whether to save" ask)))

(defcustom ebib-keywords-use-only-file nil
  "Whether or not to use only keywords from the keywords file.
If both `ebib-keywords-list' and `ebib-keywords-file' are set,
should the file take precedence or should both sets of keywords
be combined?

For .bib files that do not have an associated keywords file,
`ebib-keyword-list' is always used, regardless of this setting."
  :group 'ebib
  :type '(choice (const :tag "Use only keywords file" t)
                 (const :tag "Use keywords file and list" nil)))

(defcustom ebib-keywords-separator "; "
  "String for separating keywords in the keywords field."
  :group 'ebib
  :type '(string :tag "Keyword separator:"))

(defcustom ebib-rc-file "~/.ebibrc"
  "Customization file for Ebib.
This file is read when Ebib is started. It can be used to define
custom keys or set custimzation variables (though the latter is
easier through Customize)."
  :group 'ebib
  :type '(file :tag "Customization file:"))

(defcustom ebib-keywords-field-keep-sorted nil
  "Keep the keywords field sorted in alphabetical order.
Also automatically remove duplicates."
  :group 'ebib
  :type '(choice (const :tag "Sort keywords field" t)
                 (const :tag "Do not sort keywords field" nil)))

(defvar ebib-unique-field-list nil
  "Holds a list of all field names.")

(defun ebib-set-unique-field-list (var value)
  "Set EBIB-UNIQUE-FIELD-LIST on the basis of EBIB-ENTRY-TYPES"
  (set-default var value)
  (setq ebib-unique-field-list nil)
  (mapc #'(lambda (entry)
            (mapc #'(lambda (field)
                      (add-to-list 'ebib-unique-field-list field t 'eq))
                  (cadr entry))
            (mapc #'(lambda (field)
                      (add-to-list 'ebib-unique-field-list field t 'eq))
                  (cl-caddr entry)))
        value))

(defcustom ebib-entry-types
  '(("article"                                   ;; name of entry type
     ("author" "title" "journal" "year")         ;; obligatory fields
     ("volume" "number" "pages" "month" "note")) ;; optional fields

    ("book"
     ("author" "title" "publisher" "year")
     ("editor" "volume" "number" "series" "address" "edition" "month" "note"))

    ("booklet"
     ("title")
     ("author" "howpublished" "address" "month" "year" "note"))

    ("inbook"
     ("author" "title" "chapter" "pages" "publisher" "year")
     ("editor" "volume" "series" "address" "edition" "month" "note"))

    ("incollection"
     ("author" "title" "booktitle" "publisher" "year")
     ("editor" "volume" "number" "series" "type" "chapter" "pages" "address" "edition" "month" "note"))

    ("inproceedings"
     ("author" "title" "booktitle" "year")
     ("editor" "pages" "organization" "publisher" "address" "month" "note"))

    ("manual"
     ("title")
     ("author" "organization" "address" "edition" "month" "year" "note"))

    ("misc"
     ()
     ("title" "author" "howpublished" "month" "year" "note"))

    ("mastersthesis"
     ("author" "title" "school" "year")
     ("address" "month" "note"))

    ("phdthesis"
     ("author" "title" "school" "year")
     ("address" "month" "note"))

    ("proceedings"
     ("title" "year")
     ("editor" "publisher" "organization" "address" "month" "note"))

    ("techreport"
     ("author" "title" "institution" "year")
     ("type" "number" "address" "month" "note"))

    ("unpublished"
     ("author" "title" "note")
     ("month" "year")))

  "List of entry type definitions for Ebib"
  :group 'ebib
  :type '(repeat (list :tag "Entry type" (string :tag "Name")
                       (repeat :tag "Obligatory fields" (string :tag "Field"))
                       (repeat :tag "Optional fields" (string :tag "Field"))))
  :set 'ebib-set-unique-field-list)

(defgroup ebib-faces nil "Faces for Ebib" :group 'ebib)

(defface ebib-crossref-face '((t (:foreground "red")))
  "Face used to indicate values inherited from crossreferenced entries."
  :group 'ebib-faces)

(defface ebib-marked-face (if (featurep 'xemacs)
                              '((t (:foreground "white" :background "red")))
                            '((t (:inverse-video t))))
  "Face to indicate marked entries."
  :group 'ebib-faces)

(defface ebib-field-face '((t (:inherit font-lock-keyword-face)))
  "Face for field names."
  :group 'ebib-faces)

;; generic for all databases

;; constants and variables that are set only once
(defconst ebib-bibtex-identifier "[^^\"@\\&$#%',={}() \t\n\f]*" "Regexp describing a licit BibTeX identifier.")
(defconst ebib-key-regexp "[^^\"@\\&$#%',={} \t\n\f]*" "Regexp describing a licit key.")
(defconst ebib-version "==VERSION==")
(defvar ebib-initialized nil "T if Ebib has been initialized.")
;; "\"@',\#}{~%&$^"

;; buffers and highlights
(defvar ebib-index-buffer nil "The index buffer.")
(defvar ebib-entry-buffer nil "The entry buffer.")
(defvar ebib-strings-buffer nil "The strings buffer.")
(defvar ebib-multiline-buffer nil "Buffer for editing multiline strings.")
(defvar ebib-log-buffer nil "Buffer showing warnings and errors during loading of .bib files")
(defvar ebib-index-highlight nil "Highlight to mark the current entry.")
(defvar ebib-fields-highlight nil "Highlight to mark the current field.")
(defvar ebib-strings-highlight nil "Highlight to mark the current string.")

;; general bookkeeping
(defvar ebib-minibuf-hist nil "Holds the minibuffer history for Ebib")
(defvar ebib-saved-window-config nil "Stores the window configuration when Ebib is called.")
(defvar ebib-pre-ebib-window nil "The window that was active when Ebib was called.")
(defvar ebib-pre-multiline-buffer nil "The buffer in the window before switching to the multiline edit buffer.")
(defvar ebib-export-filename nil "Filename to export entries to.")
(defvar ebib-push-buffer nil "Buffer to push entries to.")
(defvar ebib-search-string nil "Stores the last search string.")
(defvar ebib-editing nil "Indicates what the user is editing.
Its value can be 'strings, 'fields, or 'preamble.")
(defvar ebib-multiline-unbraced nil "Indicates whether the multiline text being edited is unbraced.")
(defvar ebib-log-error nil "Indicates whether an error was logged.")
(defvar ebib-local-bibtex-filenames nil
  "A buffer-local variable holding a list of the name(s) of that buffer's .bib file(s)")
(make-variable-buffer-local 'ebib-local-bibtex-filenames)
(defvar ebib-syntax-table (make-syntax-table) "Syntax table used for reading .bib files.")
(modify-syntax-entry ?\[ "." ebib-syntax-table)
(modify-syntax-entry ?\] "." ebib-syntax-table)
(modify-syntax-entry ?\( "." ebib-syntax-table)
(modify-syntax-entry ?\) "." ebib-syntax-table)
(modify-syntax-entry ?\" "w" ebib-syntax-table)

;; keywords
;;
;; `ebib-keywords-files-alist' lists directories with keywords
;; files plus the keywords in them. if there is a single keywords
;; file, then there is only one entry. entries have three
;; elements: the dir (or full filename in case of a single
;; keywords file), a list of saved keywords, and a list of new
;; keywords added during the current session.
(defvar ebib-keywords-files-alist nil "Alist of keywords files.")

;; `ebib-keywords-list-per-session' is composed of the keywords
;; in `ebib-keywords-list' and whatever new keywords are added by
;; the user during the current session. these new additions are
;; discarded when ebib is closed.
(defvar ebib-keywords-list-per-session nil "List of keywords for the current session.")

;; the databases

;; the master list and the current database
(defvar ebib-databases nil "List of structs containing the databases.")
(defvar ebib-cur-db nil "The database that is currently active.")
(defvar ebib-cur-keys-list nil "Sorted list of entry keys in the current database.")

;;;;;; bookkeeping required when editing field values or @STRING definitions

(defvar ebib-hide-hidden-fields t "If set to T, hidden fields are not shown.")

;; this variable is set when the user enters the entry buffer
(defvar ebib-cur-entry-fields nil "The fields of the type of the current entry.")

;; this variable is set by EBIB-FILL-ENTRY-BUFFER
(defvar ebib-current-field nil "The current field.")

;; these variables are set by EBIB-FILL-STRINGS-BUFFER
(defvar ebib-current-string nil "The current @STRING definition.")
(defvar ebib-cur-strings-list nil "List of the @STRING definition in EBIB-CUR-DB.")

;; the prefix key and the multiline key are stored in a variable so that the
;; user can customise them.
(defvar ebib-prefix-key ?\;)
(defvar ebib-multiline-key ?\|)

;; this is an AucTeX variable, but we want to check its value, so let's
;; keep the compiler from complaining.
(eval-when-compile
  (defvar TeX-master))

;; this is to keep XEmacs from complaining.
(eval-when-compile
  (if (featurep 'xemacs)
      (defvar mark-active)))

;; XEmacs has line-number, not line-number-at-pos.
(eval-and-compile
  (if (featurep 'xemacs)
      (defalias 'line-number-at-pos 'line-number)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; useful macros and functions ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; we sometimes (often, in fact ;-) need to do something with a string, but
;; take special action (or do nothing) if that string is empty.
;; EBIB-IFSTRING makes that easier:

(defmacro ebib-ifstring (bindvar then &rest else)
  "Execute THEN only if STRING is nonempty.
Format: (ebib-ifstring (var value) then-form [else-forms]) VAR is bound
to VALUE, which is evaluated. If VAR is a nonempty string,
THEN-FORM is executed. If VAR is either \"\" or nil, ELSE-FORM is
executed. Returns the value of THEN or of ELSE."
  (declare (indent 2))
  `(let ,(list bindvar)
     (if (not (or (null ,(car bindvar))
                  (equal ,(car bindvar) "")))
         ,then
       ,@else)))

(defmacro ebib-last1 (lst &optional n)
  "Returns the last (or Nth last) element of LST."
  `(car (last ,lst ,n)))

;; we sometimes need to walk through lists.  these functions yield the
;; element directly preceding or following ELEM in LIST. in order to work
;; properly, ELEM must be unique in LIST, obviously. if ELEM is the
;; first/last element of LIST, or if it is not contained in LIST at all,
;; the result is nil.
(defun ebib-next-elem (elem list)
  "Return the element following ELEM in LIST.
If ELEM is the last element in LIST, or not contained in LIST,
return NIL."
  (cadr (member elem list)))

(defun ebib-prev-elem (elem list)
  "Return the element preceding ELEM in LIST.
If ELEM is the first element in LIST, or not contained in LIST,
return NIL."
  (if (or (equal elem (car list))
          (not (member elem list)))
      nil
    (ebib-last1 list (1+ (length (member elem list))))))

(defun ebib-ensure-extension (string ext)
  "Return STRING with the extension EXT appended.
If STRING already has the extension EXT, return STRING.
EXT should not contain a dot."
  (if (string-match (concat "\\." ext "$") string)
      string
    (concat string "." ext)))

(defmacro with-ebib-buffer-writable (&rest body)
  "Make the current buffer writable and execute BODY.
After BODY is executed, the buffer modified flag is unset."
  (declare (indent defun))
  `(unwind-protect
       (let ((buffer-read-only nil))
         ,@body)
     (set-buffer-modified-p nil)))

(defmacro ebib-write-region-safely (start end filename &optional append visit lockname mustbenew)
  "Compatibility macro for `write-region' in XEmacs.
XEmacs' `write-region' does not have the MUSTBENEW argument."
  (if (featurep 'xemacs)
      `(if (and (file-exists-p ,filename)
                (not (y-or-n-p (format "File %s already exists; overwrite anyway? " ,filename))))
           (error "File %s exist" ,filename)
         (write-region ,start ,end ,filename ,append ,visit ,lockname))
    `(write-region ,start ,end ,filename ,append ,visit ,lockname ,mustbenew)))

;; XEmacs doesn't know about propertize...
(if (not (fboundp 'propertize))
    (defun propertize (string &rest properties)
      "Return a copy of STRING with text properties added.
First argument is the string to copy.  Remaining arguments form a
sequence of PROPERTY VALUE pairs for text properties to add to
the result."
      (let ((new-string (copy-sequence string)))
        (add-text-properties 0 (length new-string) properties new-string)
        new-string)))

(defun ebib-multiline-p (string)
  "Return T if STRING is multiline."
  (if (stringp string)
      (string-match "\n" string)))

(defun ebib-first-line (string)
  "Return the first line of a multiline string."
  (string-match "\n" string)
  (substring string 0 (match-beginning 0)))

(defun ebib-insert-sorted (str &optional @string)
  "Insert STR into the current buffer in sort order.
The lines in the buffer contents must be sorted A-Z. STR is
inserted according to the sort order.

STR may be an entry key (in the index buffer) or an @string
abbreviation (in the strings buffer). In the latter case, the
optional argument @STRING should contain the string that STR
abbreviates.

This function leaves POINT at the beginning of the newly inserted
STR."
  ;; TODO test the calculation of upper
  (let* ((upper (progn
                  (goto-char (point-max))
                  (line-number-at-pos)))
         (limit upper)
         middle)
    (when (> limit 0)
      (let ((lower 0))
        (goto-char (point-min))
        (while (progn
                 (setq middle (/ (+ lower upper 1) 2))
                 (goto-char (point-min))
                 (forward-line (1- middle)) ; if this turns out to be where we need to be,
                 (beginning-of-line)   ; this puts POINT at the right spot.
                 ;; if upper and lower differ by only 1, we have found the
                 ;; position to insert the entry in.
                 (> (- upper lower) 1))
          (save-excursion
            (let ((beg (point)))
              (end-of-line)
              (if (string< (buffer-substring-no-properties beg (point)) str)
                  (setq lower middle)
                (setq upper middle)))))
        (if @string
            (insert (format "%-19s %s\n" str @string))
          (ebib-insert-display-key str))
        (forward-line -1)))))

(defun ebib-looking-at-goto-end (str &optional match)
  "Like LOOKING-AT but moves point to the end of the matching string.
MATCH acts just like the argument to MATCH-END, and defaults to 0."
  (or match (setq match 0))
  (let ((case-fold-search t))
    (if (looking-at str)
        (goto-char (match-end match)))))

;; this needs to be wrapped in an eval-and-compile, to keep Emacs from
;; complaining that ebib-execute-helper isn't defined when it compiles
;; ebib-execute-when.
(eval-and-compile
  (defun ebib-execute-helper (env)
    "Helper function for EBIB-EXECUTE-WHEN."
    (cond
     ((eq env 'entries)
      '(and ebib-cur-db
            (ebib-db-get-current-entry-key ebib-cur-db)))
     ((eq env 'marked-entries)
      '(and ebib-cur-db
            (ebib-db-marked-entry-list ebib-cur-db)))
     ((eq env 'database)
      'ebib-cur-db)
     ((eq env 'no-database)
      '(not ebib-cur-db))
     (t t))))

(defmacro ebib-execute-when (&rest forms)
  "Execute code conditionally based on Ebib's state.
This functions essentially like a COND clause: the basic format
is (ebib-execute-when FORMS ...), where each FORM is built up
as (ENVIRONMENTS BODY). ENVIRONMENTS is a list of symbols (not
quoted) that specify under which conditions BODY is to be
executed. Valid symbols are:

`entries': execute when there are entries in the database,
`marked-entries': execute when there are marked entries in the database,
`database': execute if there is a database,
`no-database': execute if there is no database,
`default': execute if all else fails.

Just like with COND, only one form is actually executed, the
first one that matches. If ENVIRONMENT contains more than one
condition, BODY is executed if they all match (i.e., the
conditions are AND'ed.)"
  (declare (indent defun))
  `(cond
    ,@(mapcar #'(lambda (form)
                  (cons (if (= 1 (length (car form)))
                            (ebib-execute-helper (caar form))
                          `(and ,@(mapcar #'(lambda (env)
                                              (ebib-execute-helper env))
                                          (car form))))
                        (cdr form)))
              forms)))

(defun ebib-called-with-prefix ()
  "Return T if the command was called with a prefix key.
Note: this is not a prefix argument but the prefix key that is
used to apply a command to all marked entries (by default `;')."
  (if (featurep 'xemacs)
      (member (character-to-event ebib-prefix-key) (append (this-command-keys) nil))
    (member (event-convert-list (list ebib-prefix-key))
            (append (this-command-keys-vector) nil))))

(defun ebib-temp-window ()
  "Return a window to be used for temporary use."
  (if (eq ebib-layout 'full)
      (get-buffer-window ebib-entry-buffer)
    ebib-pre-ebib-window))

(defun ebib-get-obl-fields (entry-type)
  "Return the obligatory fields of ENTRY-TYPE."
  (nth 1 (assoc entry-type ebib-entry-types)))

(defun ebib-get-opt-fields (entry-type)
  "Return the optional fields of ENTRY-TYPE."
  (nth 2 (assoc entry-type ebib-entry-types)))

(defun ebib-get-all-fields (entry-type)
  "Return all the fields of ENTRY-TYPE."
  (cons "=type=" (append (ebib-get-obl-fields entry-type)
                       (ebib-get-opt-fields entry-type)
                       ebib-additional-fields)))

(defun ebib-cur-entry-key ()
  "Return the key of the current entry."
  (ebib-db-get-current-entry-key ebib-cur-db))

(defun ebib-erase-buffer (buffer)
  "Make BUFFER writable and erase it."
  (with-current-buffer buffer
    (with-ebib-buffer-writable
      (erase-buffer))))

(defun ebib-make-highlight (begin end buffer)
  "Create an overlay (GNU Emacs) or an extent (XEmacs)."
  (let (highlight)
    (if (featurep 'xemacs)
        (progn
          (setq highlight (make-extent begin end buffer))
          (set-extent-face highlight 'highlight))
      (progn
        (setq highlight (make-overlay begin end buffer))
        (overlay-put highlight 'face 'highlight)))
    highlight))

(defun ebib-move-highlight (highlight begin end buffer)
  "Move an overlay (GNU Emacs) or an extent (XEmacs)."
  (if (featurep 'xemacs)
      (set-extent-endpoints highlight begin end buffer)
    (move-overlay highlight begin end buffer)))

(defun ebib-highlight-start (highlight)
  "Return the start of an overlay (GNU Emacs) or an extent (XEmacs)."
  (if (featurep 'xemacs)
      (extent-start-position highlight)
    (overlay-start highlight)))

(defun ebib-highlight-end (highlight)
  "Return the end of an overlay (GNU Emacs) or an extent (XEmacs)."
  (if (featurep 'xemacs)
      (extent-end-position highlight)
    (overlay-end highlight)))

(defun ebib-delete-highlight (highlight)
  "Delete an overlay (GNU Emacs) or an extent (XEmacs)."
  (if (featurep 'xemacs)
      (detach-extent highlight)
    (delete-overlay highlight)))

(defun ebib-set-index-highlight ()
  "Set the index highlight on the current entry."
  (with-current-buffer ebib-index-buffer
    (beginning-of-line)
    (let ((beg (point)))
      (if ebib-index-display-fields
          (end-of-line)
        (skip-chars-forward "^ "))
      (ebib-move-highlight ebib-index-highlight beg (point) ebib-index-buffer)
      (beginning-of-line))))

(defun ebib-set-fields-highlight ()
  "Set the field highlight on the current field."
  (with-current-buffer ebib-entry-buffer
    (beginning-of-line)
    (let ((beg (point)))
      (ebib-looking-at-goto-end "[^ \t\n\f]*")
      (ebib-move-highlight ebib-fields-highlight beg (point) ebib-entry-buffer)
      (beginning-of-line))))

(defun ebib-set-strings-highlight ()
  "Set the strings highlight on the current string."
  (with-current-buffer ebib-strings-buffer
    (beginning-of-line)
    (let ((beg (point)))
      (ebib-looking-at-goto-end "[^ \t\n\f]*")
      (ebib-move-highlight ebib-strings-highlight beg (point) ebib-strings-buffer)
      (beginning-of-line))))

(defun ebib-insert-display-key (entry-key)
  "Insert ENTRY-KEY at POINT.
The values of the fields listed in `ebib-index-display-fields'
are inserted as well. This function is solely for use in the
index buffer."
  (insert (format "%-30s %s\n"
                  entry-key
                  (if ebib-index-display-fields
                      (let ((entry-alist (ebib-db-get-entry entry-key ebib-cur-db)))
                        (mapconcat #'(lambda (field)
                                       (or
                                        (ebib-db-unbrace (car (assoc field entry-alist)))
                                        ""))
                                   ebib-index-display-fields
                                   "  "))
                    ""))))

(defun ebib-redisplay-current-field ()
  "Redisplays the contents of the current field in the entry buffer."
  (with-current-buffer ebib-entry-buffer
    (if (string= ebib-current-field "crossref")
        (progn
          (ebib-fill-entry-buffer)
          (setq ebib-current-field "crossref")
          (re-search-forward "^crossref")
          (ebib-set-fields-highlight))
      (with-ebib-buffer-writable
        (goto-char (ebib-highlight-start ebib-fields-highlight))
        (let ((beg (point)))
          (end-of-line)
          (delete-region beg (point)))
        (insert (propertize (format "%-17s " ebib-current-field) 'face 'ebib-field-face)
                (ebib-get-field-highlighted ebib-current-field (ebib-cur-entry-key)))
        (ebib-set-fields-highlight)))))

(defun ebib-redisplay-current-string ()
  "Redisplay the current string definition in the strings buffer."
  (with-current-buffer ebib-strings-buffer
    (with-ebib-buffer-writable
      (let ((str (ebib-db-get-string ebib-current-string ebib-cur-db 'noerror 'unbraced)))
        (goto-char (ebib-highlight-start ebib-strings-highlight))
        (let ((beg (point)))
          (end-of-line)
          (delete-region beg (point)))
        (insert (format "%-18s %s" ebib-current-string
                        (if (ebib-multiline-p str)
                            (concat "+" (ebib-first-line str))
                          (concat " " str))))
        (ebib-set-strings-highlight)))))

(defun ebib-move-to-current-field (direction)
  "Move the fields highlight to the line containing EBIB-CURRENT-FIELD.
If DIRECTION is positive, searches forward, if DIRECTION is
negative, searches backward. If DIRECTION is 1 or -1, searches
from POINT, if DIRECTION is 2 or -2, searches from beginning or
end of buffer."
  (with-current-buffer ebib-entry-buffer
    (if (string= field "=type=")
        (goto-char (point-min))
      (cl-multiple-value-bind (fn start limit) (if (>= direction 0)
                                                   (values 're-search-forward (point-min) (point-max))
                                                 (values 're-search-backward (point-max) (point-min)))
        ;; make sure we can get back to our original position, if the field
        ;; cannot be found in the buffer:
        (let ((current-pos (point)))
          (when (eq (logand direction 1) 0) ; if direction is even
            (goto-char start))
          (unless (funcall fn (concat "^" ebib-current-field) limit t)
            (goto-char current-pos)))))
    (ebib-set-fields-highlight)))

(defun ebib-get-field-highlighted (field key &optional match-str)
  "Return the value of FIELD of entry KEY in EBIB-CUR-DB for display in the entry buffer.
The value is returned without braces. If MATCH-STRING is non-NIL,
every occurrence of MATCH-STRING in the value of FIELD is
highlighted. If the value of FIELD is unbraced, a \"*\" is
prepended; if it is multiline, a \"+\" is prepended."
  ;; Note: we need to work on a copy of the string, otherwise the highlights
  ;; are made to the string as stored in the database. Hence copy-sequence.
  (let* ((case-fold-search t)
         (value (ebib-db-get-field-value field key ebib-cur-db 'noerror nil 'xref))
         (string (if (car value)
                     (copy-sequence (car value))))
         (xref (cadr value))
         (unbraced " ")
         (multiline " ")
         (matched nil))
    ;; we have to do a couple of things now:
    ;; - remove {} or "" around the string, if they're there
    ;; - search for match-str
    ;; - properly adjust the string if it's multiline
    ;; but all this is not necessary if there was no string
    (when string
      (if xref
          (setq string (propertize string 'face 'ebib-crossref-face 'fontified t)))
      (if (ebib-db-unbraced-p string)
          (setq unbraced "*")
        (setq string (ebib-db-unbrace string))) ; we have to make the string look nice
      (when match-str
        (multiple-value-setq (string matched) (ebib-match-all match-str string)))
      (when (ebib-multiline-p string)
        ;; IIUC PROPERTIZE shouldn't be necessary here, as the variable
        ;; multiline is local and therefore the object it refers to should
        ;; be GC'ed when the function returns. but for some reason, the
        ;; plus sign is persistent, and if it's been highlighted as the
        ;; result of a search, it stays that way.
        (setq multiline (propertize "+" 'face nil))
        (setq string (ebib-first-line string)))
      (when (and matched
                 (string= multiline "+"))
        (add-text-properties 0 1 '(face highlight) multiline)))
    (concat unbraced multiline string)))

(defun ebib-match-all (match-str string)
  "Highlight all occurrences of MATCH-STR in STRING.
The return value is a list of two elements: the first is the
modified string, the second either t or nil, indicating whether a
match was found at all."
  (do ((counter 0 (match-end 0)))
      ((not (string-match match-str string counter)) (values string (not (= counter 0))))
    (add-text-properties (match-beginning 0) (match-end 0) '(face highlight) string)))

(defun ebib-display-fields (key &optional match-str)
  "Insert the fields and values of entry KEY in the current buffer.
Each field is displayed on a separate line, the field name is
highlighted with `ebib-field-face', the field value is prepended
with a \"*\" if it is unbraced and with a \"+\" if it is
multiline."
  (let* ((entry (ebib-db-get-entry key ebib-cur-db))
         (entry-type (cdr (assoc "=type=" entry)))
         (obl-fields (ebib-get-obl-fields entry-type))
         (opt-fields (ebib-get-opt-fields entry-type)))
    (insert (format "%-19s %s\n" (propertize "type" 'face 'ebib-field-face) entry-type))
    (mapc #'(lambda (fields)
              (insert "\n")
              (mapcar #'(lambda (field)
                          (unless (and (member field ebib-hidden-fields)
                                       ebib-hide-hidden-fields)
                            (insert (propertize (format "%-17s " field) 'face 'ebib-field-face))
                            (insert (or
                                         (ebib-get-field-highlighted field key match-str)
                                         ""))
                            (insert "\n")))
                      fields))
          (list obl-fields opt-fields ebib-additional-fields))))

(defun ebib-fill-entry-buffer (&optional match-str)
  "Fill the entry buffer with the fields of the current entry.
MATCH-STRING is a regexp that will be highlighted when it occurs in the
field contents.

If there is no database, the buffer is just erased."
  (with-current-buffer ebib-entry-buffer
    (with-ebib-buffer-writable
      (erase-buffer)
      ;; TODO the following could probably be done with ebib-execute-when:
      (when (and ebib-cur-db            ; do we have a database?
                 (ebib-db-get-entry (ebib-cur-entry-key) ebib-cur-db 'noerror)) ; does the current entry exist?
        (ebib-display-fields (ebib-cur-entry-key) 'insert match-str)
        (setq ebib-current-field "=type=")
        (goto-char (point-min))
        (ebib-set-fields-highlight)))))

(defun ebib-set-modified (mod)
  "Set the modified flag of the current database to MOD.
The modified flag of the index buffer is also (re)set. MOD must
be either T or NIL."
  (ebib-db-set-modified mod ebib-cur-db)
  (with-current-buffer ebib-index-buffer
    (set-buffer-modified-p mod)))

(defun ebib-modified-p ()
  "Check if any of the databases have been modified.
Return the first modified database, or NIL if none was modified."
  (let ((db (car ebib-databases)))
    (while (and db
                (not (ebib-db-modified-p db)))
      (setq db (ebib-next-elem db ebib-databases)))
    db))

(defun ebib-match-paren-forward (limit)
  "Move forward to the closing parenthesis matching the opening parenthesis at POINT.
This function handles parentheses () and braces {}. Do not
search/move beyond LIMIT. Return T if a matching parenthesis was
found, NIL otherwise. If point was not at an opening parenthesis
at all, NIL is returned and point is not moved. If point was at
an opening parenthesis but no matching closing parenthesis was
found, an error is logged and point is moved one character
forward to allow parsing to continue."
  (cond
   ((eq (char-after) ?\{)
    (ebib-match-brace-forward limit))
   ((eq (char-after) ?\()
    ;; we wrap this in a condition-case because we need to log the error
    ;; message outside of the save-restriction, otherwise we get the wrong
    ;; line number.
    (condition-case nil
        (save-restriction
          (narrow-to-region (point) limit)
          ;; this is really a hack. we want to allow unbalanced parentheses in
          ;; field values (bibtex does), so we cannot use forward-list
          ;; here. for the same reason, looking for the matching paren by hand
          ;; is pretty complicated. however, balanced parentheses can only be
          ;; used to enclose entire entries (or @STRINGs or @PREAMBLEs) so we
          ;; can be pretty sure we'll find it right before the next @ at the
          ;; start of a line, or right before the end of the file.
          (re-search-forward "^@" nil 0)
          (skip-chars-backward "@ \n\t\f")
          (forward-char -1)
          (if (eq (char-after) ?\))
              t
            (goto-char (1+ (point-min)))
            (error "")))
      (error (ebib-log 'error "Error in line %d: Matching closing parenthesis not found!" (line-number-at-pos))
             nil)))
   (t nil)))

(defun ebib-match-delim-forward (limit)
  "Move forward to the closing delimiter matching the opening delimiter at POINT.
This function handles braces {} and double quotes \"\". Do not
search/move beyond LIMIT. Return T if a matching delimiter was
found, NIL otherwise. If point was not at an opening delimiter at
all, NIL is returned and point is not moved. If point was at an
opening delimiter but no matching closing delimiter was found, an
error is logged and point is moved one character forward to allow
parsing to continue."
  (cond
   ((eq (char-after) ?\")
    (ebib-match-quote-forward limit))
   ((eq (char-after) ?\{)
    (ebib-match-brace-forward limit))
   (t nil)))

(defun ebib-match-brace-forward (limit)
  "Move forward to the closing brace matching the opening brace at POINT.
Do not search/move beyond LIMIT. Return T if a matching brace was
found, NIL otherwise. If point was not at an opening brace at
all, NIL is returned and point is not moved. If point was at an
opening brace but no matching closing brace was found, an error
is logged and point is moved one character forward to allow
parsing to continue."
  (when (eq (char-after) ?\{) ; make sure we're really on a brace, otherwise return nil
    (condition-case nil
        (save-restriction
          (narrow-to-region (point) limit)
          (progn
            (forward-list)
            ;; all of ebib expects that point moves to the closing
            ;; parenthesis, not right after it, so we adjust.
            (forward-char -1)
            t))               ; return t because a matching brace was found
      (error (progn
               (ebib-log 'error "Error in line %d: Matching closing brace not found!" (line-number-at-pos))
               (forward-char 1)
               nil)))))

(defun ebib-match-quote-forward (limit)
  "Move to the closing double quote matching the quote at POINT.
Do not search/move beyond LIMIT. Return T if a matching quote was
found, NIL otherwise. If point was not at a double quote at all,
NIL is returned and point is not moved. If point was at a quote
but no matching closing quote was found, an error is logged and
point is moved one character forward to allow parsing to
continue."
  (when (eq (char-after (point)) ?\")  ; make sure we're on a double quote.
    (condition-case nil
        (save-restriction
          (narrow-to-region (point) limit)
          (while (progn
                   (forward-char) ; move forward because we're on a double quote
                   (skip-chars-forward "^\"") ; search the next double quote
                   (eq (char-before) ?\\))) ; if it's preceded by a backslash, keep on searching
          (or (eq (char-after) ?\")
              (progn
                (goto-char (1+ (point-min)))
                (error ""))))
      (error (ebib-log 'error "Error in line %d: Matching closing quote not found!" (line-number-at-pos))
             nil))))

(defun ebib-store-entry (entry-key fields &optional sort timestamp)
  "Store the entry defined by ENTRY-KEY and FIELDS into EBIB-CUR-DB.
If optional argument SORT is T, EBIB-CUR-KEYS-LIST is sorted
after insertion. If optional argument TIMESTAMP is T and
EBIB-USE-TIMESTAMP is set, a timestamp is added to the entry."
  (when (and timestamp ebib-use-timestamp)
    (add-to-list 'fields "timestamp" (ebib-db-brace (format-time-string ebib-timestamp-format))))
  (ebib-db-set-entry entry-key fields ebib-cur-db (if ebib-uniquify-keys 'uniquify))
  (ebib-set-modified t)
  (setq ebib-cur-keys-list
        (if sort
            (ebib-db-list-keys ebib-cur-db)
          (cons entry-key ebib-cur-keys-list))))

(defun ebib-store-string (abbr string &optional sort)
  "Store STRING in EBIB-CUR-DB under @string identifier ABBR.
Any existing @string value for ABBR is overwritten. Optional
argument SORT indicates whether the STRINGS-LIST must be sorted
after insertion."
  (ebib-db-set-string abbr (ebib-db-brace string) ebib-cur-db 'overwrite)
  (ebib-set-modified t)
  (setq ebib-cur-strings-list
        (if sort
            (sort (cons abbr ebib-cur-strings-list) 'string<)
          (cons abbr ebib-cur-strings-list))))

(defun ebib-search-key-in-buffer (entry-key)
  "Search ENTRY-KEY in the index buffer.
Move point to the first character of the key and return point."
  (goto-char (point-min))
  (re-search-forward (concat "^" entry-key))
  (beginning-of-line)
  (point))

;; when we sort entries, we either use string< on the entry keys, or
;; ebib-entry<, if the user has defined a sort order.

(defun ebib-entry< (x y)
  "Return T if entry X precedes entry Y according to EBIB-SORT-ORDER.
X and Y should be entry keys in the current database."
  (let* ((sort-list ebib-sort-order)
         (sortstring-x (ebib-get-sortstring x (car sort-list)))
         (sortstring-y (ebib-get-sortstring y (car sort-list))))
    (while (and sort-list
                (string= sortstring-x sortstring-y))
      (setq sort-list (cdr sort-list))
      (setq sortstring-x (ebib-get-sortstring x (car sort-list)))
      (setq sortstring-y (ebib-get-sortstring y (car sort-list))))
    (if (and sortstring-x sortstring-y)
        (string< sortstring-x sortstring-y)
      (string< x y))))

(defun ebib-get-sortstring (entry-key sortkey-list)
  "Return the field value on which the entry ENTRY-KEY is to be sorted.
ENTRY-KEY must be the key of an entry in the current database.
SORTKEY-LIST is a list of fields that are considered in order for
the sort value.

The braces around the returned field value are removed."
  (let ((sort-string nil))
    (while (and sortkey-list
                (null (setq sort-string (ebib-db-get-field-value (car sortkey-list) entry-key ebib-cur-db 'noerror 'unbraced))))
      (setq sortkey-list (cdr sortkey-list)))
    sort-string))

(defvar ebib-info-flag nil "Flag to indicate whether Ebib called Info or not.")

(defadvice Info-exit (after ebib-info-exit activate)
  "Quit info and return to Ebib, if Info was called from there."
  (when ebib-info-flag
    (setq ebib-info-flag nil)
    (ebib)))

(defun ebib-read-file-to-list (filename)
  "Return a list of lines from file FILENAME."
  (if (and filename                ; protect against 'filename' being 'nil'
           (file-readable-p filename))
      (with-temp-buffer
        (insert-file-contents filename)
        (split-string (buffer-string) "\n" t)))) ; 't' is omit nulls, blank lines in this case

(defun ebib-keywords-load-keywords (db)
  "Check if there is a keywords file for DB and make sure it is loaded."
  (unless (or (string= ebib-keywords-file "")
              (file-name-directory ebib-keywords-file))
    (let ((dir (expand-file-name (file-name-directory (ebib-db-get-filename db)))))
      (if dir
          (let ((keyword-list (ebib-read-file-to-list (concat dir ebib-keywords-file))))
            ;; note: even if keyword-list is empty, we store it, because the user
            ;; may subsequently add keywords.
            (add-to-list 'ebib-keywords-files-alist    ; add the dir if not in the list yet
                         (list dir keyword-list ())   ; the extra empty list is for new keywords
                         t #'(lambda (x y) (equal (car x) (car y)))))))))

(defun ebib-keywords-add-keyword (keyword db)
  "Add KEYWORD to the list of keywords for DB."
  (if (string= ebib-keywords-file "")   ; only the general list exists
      (add-to-list 'ebib-keywords-list-per-session keyword t)
    (let ((dir (or (file-name-directory ebib-keywords-file) ; a single keywords file
                   (file-name-directory (ebib-db-get-filename db))))) ; per-directory keywords files
      (push keyword (third (assoc dir ebib-keywords-files-alist))))))

(defun ebib-keywords-for-database (db)
  "Return the list of keywords for database DB.
When the keywords come from a file, add the keywords in
EBIB-KEYWORDS-LIST, unless EBIB-KEYWORDS-USE-ONLY-FILE is set."
  (if (string= ebib-keywords-file "")   ; only the general list exists
      ebib-keywords-list-per-session
    (let* ((dir (or (file-name-directory ebib-keywords-file) ; a single keywords file
                    (file-name-directory (ebib-db-get-filename db)))) ; per-directory keywords files
           (lst (assoc dir ebib-keywords-files-alist)))
      (append (second lst) (third lst)))))

(defun ebib-keywords-get-file (db)
  "Return the name of the keywords file for DB."
  (if (file-name-directory ebib-keywords-file)
      ebib-keywords-file
    (concat (file-name-directory (ebib-db-get-filename db)) ebib-keywords-file)))

(defun ebib-keywords-save-to-file (keyword-file-descr)
  "Save all keywords in KEYWORD-FILE-DESCR to the associated file.
KEYWORD-FILE-DESCR is an element of EBIB-KEYWORDS-FILES-ALIST,
that is, it consists of a list of three elements, the first is
the directory of the keywords file, the second the existing
keywords and the third the keywords added in this session."
  (let ((file (if (file-name-directory ebib-keywords-file)
                  ebib-keywords-file
                (concat (car keyword-file-descr) ebib-keywords-file))))
    (if (file-writable-p file)
        (with-temp-buffer
          (mapc #'(lambda (keyword)
                    (insert (format "%s\n" keyword)))
                (append (second keyword-file-descr) (third keyword-file-descr)))
          (write-region (point-min) (point-max) file))
      (ebib-log 'warning "Could not write to keyword file `%s'" file))))

(defun ebib-keywords-save-new-keywords (db)
  "Check if new keywords were added to DB and save them as required."
  (let ((lst (ebib-keywords-new-p db))
        (file (ebib-keywords-get-file db)))
    (when (and (third lst)                     ; if there are new keywords
               (or (eq ebib-keywords-file-save-on-exit 'always)
                   (and (eq ebib-keywords-file-save-on-exit 'ask)
                        (y-or-n-p "New keywords have been added. Save "))))
      (ebib-keywords-save-to-file lst)
      ;; now move the new keywords to the list of existing keywords
      (setf (cadr lst) (append (second lst) (third lst)))
      (setf (cl-caddr lst) nil))))

(defun ebib-keywords-save-cur-db ()
  "Save new keywords for the current database."
  (interactive)
  (ebib-keywords-save-new-keywords ebib-cur-db))

(defun ebib-keywords-new-p (&optional db)
  "Check whether there are new keywords.
Returns NIL if there are no new keywords, or a list containing
all the elements in EBIB-KEYWORDS-FILES-ALIST that contain new
keywords.

Optional argument DB specifies the database to check for."
  (if db
      (let* ((dir (or (file-name-directory ebib-keywords-file) ; a single keywords file
                      (file-name-directory (ebib-db-get-filename db)))) ; per-directory keywords files
             (lst (assoc dir ebib-keywords-files-alist)))
        (if (third lst)
            lst))
    (delq nil (mapcar #'(lambda (elt) ; this would be easier with cl-remove
                          (if (third elt)
                              elt))
                      ebib-keywords-files-alist))))

(defun ebib-keywords-save-all-new (&optional interactive)
  "Check if new keywords were added during the session and save them as required."
  (interactive "p")
  (let ((new (ebib-keywords-new-p)))
    (when (and new
               (or (eq ebib-keywords-file-save-on-exit 'always)
                   interactive
                   (and (eq ebib-keywords-file-save-on-exit 'ask)
                        (y-or-n-p (format "New keywords were added. Save '%s'? "
                                          (file-name-nondirectory ebib-keywords-file)))))) ; strip path for succinctness
      (mapc #'(lambda (elt)
                (ebib-keywords-save-to-file elt))
            new))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; main program execution ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun ebib (&optional key redisplay)
  "Ebib, a BibTeX database manager.
Optional argument KEY specifies the entry of the current database
that is to be displayed. Optional argument REDISPLAY specifies
whether the index and entry buffer must be redisplayed."
  (interactive)
  (if (or (equal (window-buffer) ebib-index-buffer)
          (equal (window-buffer) ebib-entry-buffer))
      (error "Ebib already active")
    ;; we save the buffer from which ebib is called
    (setq ebib-push-buffer (current-buffer))
    ;; initialize ebib if required
    (unless ebib-initialized
      (ebib-init)
      (if ebib-preload-bib-files
          (mapc #'(lambda (file)
                    (ebib-open-bibtex-file (locate-file file ebib-preload-bib-search-dirs)))
                ebib-preload-bib-files)))
    ;; if ebib is visible, we just switch to the index buffer
    (let ((index-window (get-buffer-window ebib-index-buffer)))
      (if index-window
          (select-window index-window nil)
        (ebib-setup-windows)))
    (when redisplay
      (ebib-fill-entry-buffer)
      (ebib-fill-index-buffer))
    ;; if ebib is called with an argument, we look for it
    (when key
      (let ((exists? (member key ebib-cur-keys-list)))
        (if exists?
            (progn
              (ebib-db-set-current-entry-key ebib-cur-db (car exists?))
              (with-current-buffer ebib-index-buffer
                (goto-char (point-min))
                (re-search-forward (format "^%s " (ebib-cur-entry-key)))
                (ebib-select-entry)))
          (message "No entry `%s' in current database " key))))))

(defun ebib-setup-windows ()
  "Create the window configuration for Ebib in the current window."
  ;; we save the current window configuration.
  (setq ebib-saved-window-config (current-window-configuration))
  (if (eq ebib-layout 'full)
      (delete-other-windows)
    (setq ebib-pre-ebib-window (selected-window))
    (let ((ebib-window (split-window (selected-window) (- (window-width) ebib-width) t)))
      (select-window ebib-window nil)))
  (let* ((index-window (selected-window))
         (entry-window (split-window index-window ebib-index-window-size)))
    (switch-to-buffer ebib-index-buffer)
    (set-window-buffer entry-window ebib-entry-buffer)
    (unless (eq ebib-layout 'full)
      (set-window-dedicated-p index-window t)
      (set-window-dedicated-p entry-window t))))

(defun ebib-init ()
  "Initialise Ebib.
Set all variables to their initial values, create the buffers and
read the rc file."
  (setq ebib-current-field nil
        ebib-minibuf-hist nil
        ebib-saved-window-config nil)
  (load ebib-rc-file t)
  (ebib-create-buffers)
  (if (file-name-directory ebib-keywords-file) ; returns nil if there is no directory part
      (add-to-list 'ebib-keywords-files-alist (list (file-name-directory ebib-keywords-file)
                                                    (read-file-to-list ebib-keywords-file) nil)))
  (setq ebib-keywords-list-per-session (copy-tree ebib-keywords-list))
  (setq ebib-index-highlight (ebib-make-highlight 1 1 ebib-index-buffer))
  (setq ebib-fields-highlight (ebib-make-highlight 1 1 ebib-entry-buffer))
  (setq ebib-strings-highlight (ebib-make-highlight 1 1 ebib-strings-buffer))
  (setq ebib-initialized t))

(defun ebib-create-buffers ()
  "Create the buffers for Ebib."
  ;; Unlike the other buffers, the buffer for multiline editing does *not*
  ;; have a name beginning with a space, so undo information is kept.
  (setq ebib-multiline-buffer (get-buffer-create "*Ebib-edit*"))
  (with-current-buffer ebib-multiline-buffer
    (funcall ebib-multiline-major-mode)
    (ebib-multiline-mode t))
  (setq ebib-entry-buffer (get-buffer-create " *Ebib-entry*"))
  (with-current-buffer ebib-entry-buffer
    (ebib-entry-mode))
  (setq ebib-strings-buffer (get-buffer-create " *Ebib-strings*"))
  (with-current-buffer ebib-strings-buffer
    (ebib-strings-mode))
  (setq ebib-log-buffer (get-buffer-create " *Ebib-log*"))
  (with-current-buffer ebib-log-buffer
    (erase-buffer))
  (insert "Ebib log messages\n\n(Press C-v or SPACE to scroll down, M-v or `b' to scroll up, `q' to quit.)\n\n")
  (ebib-log-mode)
  (setq ebib-index-buffer (get-buffer-create " none"))
  (with-current-buffer ebib-index-buffer
    (ebib-index-mode)))

(defun ebib-quit ()
  "Quit Ebib.
Kill all Ebib buffers and set all variables except the keymaps to nil."
  (interactive)
  (when (if (ebib-modified-p)
            (yes-or-no-p "There are modified databases. Quit anyway? ")
          (y-or-n-p "Quit Ebib? "))
    (ebib-keywords-save-all-new)
    (mapc #'(lambda (buffer)
              (kill-buffer buffer))
          (list ebib-entry-buffer
                ebib-index-buffer
                ebib-strings-buffer
                ebib-multiline-buffer
                ebib-log-buffer))
    (setq ebib-databases nil
          ebib-cur-db nil
          ebib-index-buffer nil
          ebib-entry-buffer nil
          ebib-initialized nil
          ebib-index-highlight nil
          ebib-fields-highlight nil
          ebib-strings-highlight nil
          ebib-export-filename nil
          ebib-pre-ebib-window nil
          ebib-keywords-files-alist nil
          ebib-keywords-list-per-session nil)
    (set-window-configuration ebib-saved-window-config)
    (message "")))

(defun ebib-kill-emacs-query-function ()
  "Function to add to `kill-emacs-query-functions'."
  (when (or (not (ebib-modified-p))
            (if (y-or-n-p "Save all unsaved Ebib databases? ")
                (progn
                  (ebib-save-all-databases)
                  t)
              (yes-or-no-p "Ebib holds modified databases. Kill anyway? ")))
    (ebib-keywords-save-all-new)
    t))

(add-hook 'kill-emacs-query-functions 'ebib-kill-emacs-query-function)

;;;;;;;;;;;;;;;;
;; index-mode ;;
;;;;;;;;;;;;;;;;

(eval-and-compile
  (define-prefix-command 'ebib-prefix-map)
  (suppress-keymap ebib-prefix-map)
  (defvar ebib-prefixed-functions '(ebib-delete-entry
                                    ebib-latex-entries
                                    ebib-mark/unmark-entry
                                    ebib-print-entries
                                    ebib-push-bibtex-key
                                    ebib-export-entry)))

;; macro to redefine key bindings.

(defmacro ebib-key (buffer key &optional command)
  "Bind/unbind KEY in Ebib BUFFER.
BUFFER should be one of 'index, 'entry or 'strings. If optional
argument COMMAND is NIL, the key is unset.

BUFFER can also be 'mark-prefix, which sets the prefix key for
commands operating on marked entries, or 'multiline, which sets
the character for the commands in the multiline edit buffer."
  (cond
   ((eq buffer 'index)
    (let ((one `(define-key ebib-index-mode-map ,key (quote ,command)))
          (two (when (or (null command)
                         (member command ebib-prefixed-functions))
                 `(define-key ebib-prefix-map ,key (quote ,command)))))
      (if two
          `(progn ,one ,two)
        one)))
   ((eq buffer 'entry)
    `(define-key ebib-entry-mode-map ,key (quote ,command)))
   ((eq buffer 'strings)
    `(define-key ebib-strings-mode-map ,key (quote ,command)))
   ((eq buffer 'mark-prefix)
    `(progn
       (define-key ebib-index-mode-map (format "%c" ebib-prefix-key) nil)
       (define-key ebib-index-mode-map ,key 'ebib-prefix-map)
       (setq ebib-prefix-key (string-to-char ,key))))
   ((eq buffer 'multiline)
    `(progn
       (define-key ebib-multiline-mode-map "\C-c" nil)
       (mapc #'(lambda (command)
                 (define-key ebib-multiline-mode-map (format "\C-c%s%c" ,key (car command)) (cdr command)))
             '((?q . ebib-quit-multiline-edit)
               (?c . ebib-cancel-multiline-edit)
               (?s . ebib-save-from-multiline-edit)))
       (setq ebib-multiline-key (string-to-char ,key))))))

(defvar ebib-index-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map)
    map)
  "Keymap for the ebib index buffer.")

;; we define the keys with ebib-key rather than with define-key, because
;; that automatically sets up ebib-prefix-map as well.
(ebib-key index [up] ebib-prev-entry)
(ebib-key index [down] ebib-next-entry)
(ebib-key index [right] ebib-next-database)
(ebib-key index [left] ebib-prev-database)
(ebib-key index [prior] ebib-index-scroll-down)
(ebib-key index [next] ebib-index-scroll-up)
(ebib-key index [home] ebib-goto-first-entry)
(ebib-key index [end] ebib-goto-last-entry)
(ebib-key index [return] ebib-select-entry)
(ebib-key index " " ebib-index-scroll-up)
(ebib-key index "/" ebib-search)
(ebib-key index "&" ebib-filter-db-and)
(ebib-key index "|" ebib-filter-db-or)
(ebib-key index "~" ebib-filter-db-not)
(ebib-key index ";" ebib-prefix-map)
(ebib-key index "?" ebib-info)
(ebib-key index "a" ebib-add-entry)
(ebib-key index "b" ebib-index-scroll-down)
(ebib-key index "c" ebib-close-database)
(ebib-key index "C" ebib-follow-crossref) ; TODO change in the manual
(ebib-key index "d" ebib-delete-entry)
(ebib-key index "e" ebib-edit-entry)
(ebib-key index "E" ebib-edit-keyname)
(ebib-key index "f" ebib-view-file)
(ebib-key index "Fd" ebib-delete-filter) ; TODO manual
(ebib-key index "Fv" ebib-print-filter) ; TODO manual
(ebib-key index "g" ebib-goto-first-entry)
(ebib-key index "G" ebib-goto-last-entry)
(ebib-key index "h" ebib-index-help)
(ebib-key index "i" ebib-browse-doi)
(ebib-key index "j" ebib-next-entry)
(ebib-key index "J" ebib-switch-to-database)
(ebib-key index "k" ebib-prev-entry)
(ebib-key index "K" ebib-generate-autokey)
(ebib-key index "l" ebib-show-log)
(ebib-key index "m" ebib-mark/unmark-entry)
(ebib-key index "n" ebib-search-next)
(ebib-key index [(control n)] ebib-next-entry)
(ebib-key index [(meta n)] ebib-index-scroll-up)
(ebib-key index "o" ebib-open-bibtex-file)
(ebib-key index "p" ebib-push-bibtex-key)
(ebib-key index [(control p)] ebib-prev-entry)
(ebib-key index [(meta p)] ebib-index-scroll-down)
(ebib-key index "P" ebib-edit-preamble)
(ebib-key index "q" ebib-quit)
(ebib-key index "s" ebib-save-current-database)
(ebib-key index "S" ebib-edit-strings)
(ebib-key index "u" ebib-browse-url)
(ebib-key index "x" ebib-export-entry)
(ebib-key index "\C-xb" ebib-leave-ebib-windows)
(ebib-key index "\C-xk" ebib-quit)
(ebib-key index "X" ebib-export-preamble)
(ebib-key index "z" ebib-leave-ebib-windows)
(ebib-key index "Z" ebib-lower)

(defun ebib-switch-to-database-nth (n)
  "Switch to the Nth database.
This command is to be bound to the digit keys: the digit used to
call it is passed as argument."
  (interactive (list (if (featurep 'xemacs)
                         (event-key last-command-event)
                       last-command-event)))
  (ebib-switch-to-database (- (if (featurep 'xemacs)
                                  (char-to-int n)
                                n) 48)))

(mapc #'(lambda (key)
          (define-key ebib-index-mode-map (format "%d" key)
            'ebib-switch-to-database-nth))
      '(1 2 3 4 5 6 7 8 9))

(define-derived-mode ebib-index-mode
  fundamental-mode "Ebib-index"
  "Major mode for the Ebib index buffer."
  (setq buffer-read-only t)
  (setq truncate-lines t))

(easy-menu-define ebib-index-menu ebib-index-mode-map "Ebib index menu"
  '("Ebib"
    ["Open Database..." ebib-open-bibtex-file t]
    ["Merge Database..." ebib-merge-bibtex-file ebib-cur-db]
    ["Save Database" ebib-save-current-database (and ebib-cur-db
                                                     (ebib-db-modified-p ebib-cur-db))]
    ["Save All Databases" ebib-save-all-databases (ebib-modified-p)]
    ["Save Database As..." ebib-write-database ebib-cur-db]
    ["Close Database" ebib-close-database ebib-cur-db]
    "--"
    ["Save New Keywords For Database" ebib-keywords-save-cur-db (ebib-keywords-new-p ebib-cur-db)]
    ["Save All New Keywords" ebib-keywords-save-all-new (ebib-keywords-new-p)]
    "--"
    ("Entry"
     ["Add" ebib-add-entry ebib-cur-db]
     ["Edit" ebib-edit-entry (and ebib-cur-db
                                  (ebib-cur-entry-key))]
     ["Delete" ebib-delete-entry (and ebib-cur-db
                                      (ebib-cur-entry-key))])
    ["Edit Strings" ebib-edit-strings ebib-cur-db]
    ["Edit Preamble" ebib-edit-preamble ebib-cur-db]
    "--"
    ["Open URL" ebib-browse-url (ebib-db-get-field-value ebib-standard-url-field (ebib-cur-entry-key) ebib-cur-db)]
    ["Open DOI" ebib-browse-doi (ebib-db-get-field-value ebib-doi-url-field (ebib-cur-entry-key) ebib-cur-db)]
    ["View File" ebib-view-file (ebib-db-get-field-value ebib-file-url-field (ebib-cur-entry-key) ebib-cur-db)]
    ("Print Entries"
     ["As Bibliography" ebib-latex-entries ebib-cur-db]
     ["As Index Cards" ebib-print-entries ebib-cur-db]
     ["Print Multiline Fields" ebib-toggle-print-multiline :enable t
      :style toggle :selected ebib-print-multiline]
     ["Print Cards on Separate Pages" ebib-toggle-print-newpage :enable t
      :style toggle :selected ebib-print-newpage])
    "--"
    ("Options"
     ["Show Hidden Fields" ebib-toggle-hidden :enable t
      :style toggle :selected (not ebib-hide-hidden-fields)]
     ["Use Timestamp" ebib-toggle-timestamp :enable t
      :style toggle :selected ebib-use-timestamp]
     ["Save Cross-Referenced Entries First" ebib-toggle-xrefs-first :enable t
      :style toggle :selected ebib-save-xrefs-first]
     ["Allow Identical Fields" ebib-toggle-identical-fields :enable t
      :style toggle :selected ebib-allow-identical-fields]
     ["Full Layout" ebib-toggle-layout :enable t
      :style toggle :selected (eq ebib-layout 'full)]
     ["Modify Entry Types" ebib-customize-entry-types t]
     ["Customize Ebib" ebib-customize t])
    ["View Log Buffer" ebib-show-log t]
    ["Lower Ebib" ebib-lower t]
    ["Quit" ebib-quit t]
    ["Help on Ebib" ebib-info t]))

(easy-menu-add ebib-index-menu ebib-index-mode-map)

(defun ebib-run-filter ()
  "Run the current filter on EBIB-CUR-DB.
Set EBIB-CUR-KEYS-LIST to a list of entry keys that match the
filter."
  ;; The filter uses a macro `contains', which we locally define here. This
  ;; macro in turn uses a dynamic variable `entry', which we must set
  ;; before eval'ing the filter.
  (let ((filter `(cl-macrolet ((contains (field regexp)
                                         `(ebib-search-in-entry ,regexp entry ,(unless (string= field "any") field))))
                   ,(ebib-db-get-filter ebib-cur-db))))
    (setq ebib-cur-keys-list
          (sort (let ((result nil))
                  (mapcar #'(lambda (key)
                              (let ((entry (ebib-db-get-entry key ebib-cur-db)))
                                (when (eval filter)
                                  (setq result (cons key result)))))
                          (ebib-db-list-keys ebib-cur-db))
                  result)
                'string<)))
  (ebib-db-set-current-entry-key (car ebib-cur-keys-list) ebib-cur-db))

(defun ebib-fill-index-buffer ()
  "Fill the index buffer with the list of keys in EBIB-CUR-DB.
If a filter is active, display only the entries that match the
filter. If EBIB-CUR-DB is nil, the buffer is just erased and its
name set to \"none\".

This function sets EBIB-CUR-KEYS-LIST."
  (with-current-buffer ebib-index-buffer
    (let ((buffer-read-only nil))
      (erase-buffer)
      (if (not ebib-cur-db)
          (rename-buffer " none")
        ;; we may call this function when there are no entries in the
        ;; database. if so, we don't need to do this:
        (when (ebib-cur-entry-key)
          (if (ebib-db-get-filter ebib-cur-db)
              (ebib-run-filter)
            (setq ebib-cur-keys-list (ebib-db-list-keys ebib-cur-db)))
          (mapc #'(lambda (entry)
                    (ebib-insert-display-key entry)
                    (when (ebib-db-marked-p entry ebib-cur-db)
                      (save-excursion
                        (let ((beg (progn
                                     (beginning-of-line)
                                     (forward-line -1)
                                     (point))))
                          (skip-chars-forward "^ ")
                          (add-text-properties beg (point) '(face ebib-marked-face))))))
                ebib-cur-keys-list)
          (goto-char (point-min))
          (re-search-forward (format "^%s " (ebib-cur-entry-key)))
          (beginning-of-line)
          (ebib-set-index-highlight))
        (set-buffer-modified-p (ebib-db-modified-p ebib-cur-db))
        (rename-buffer (concat (format " %d:" (1+ (- (length ebib-databases)
                                                     (length (member ebib-cur-db ebib-databases)))))
                               (file-name-nondirectory (ebib-db-get-filename ebib-cur-db))))))))

(defun ebib-customize ()
  "Switch to Ebib's customisation group."
  (interactive)
  (ebib-lower)
  (customize-group 'ebib))

;; TODO once we use bibtex.el's entry types, this function must be adapted.
(defun ebib-customize-entry-types ()
  "Customize EBIB-ENTRY-TYPES."
  (interactive)
  (ebib-lower)
  (customize-variable 'ebib-entry-types))

(defun ebib-log (type format-string &rest args)
  "Write a message to Ebib's log buffer.
TYPE (a symbol) is the type of message. It can be 'log, which
writes the message to the log buffer only; 'message, which writes
the message to the log buffer and outputs it with the function
`message'; 'warning, which logs the message and sets the variable
`ebib-log-error' to 0; or 'error, which logs the message and sets
the variable `ebib-log-error' to 1. The latter two can be used to
signal the user to check the log for warnings or errors.

This function adds a newline to the message being logged."
  (with-current-buffer ebib-log-buffer
    (cond
     ((eq type 'warning)
      (or ebib-log-error ; if ebib-error-log is already set to 1, we don't want to overwrite it!
          (setq ebib-log-error 0)))
     ((eq type 'error)
      (setq ebib-log-error 1))
     ((eq type 'message)
      (apply 'message format-string args)))
    (insert (apply 'format  (concat (if (eq type 'error)
                                        (propertize format-string 'face 'font-lock-warning-face)
                                      format-string)
                                    "\n")
                   args))))

(defun ebib-open-bibtex-file (file)
  "Open a BibTeX file."
  (interactive (list (ebib-ensure-extension (read-file-name "File to open: " "~/") "bib")))
  (let ((new-db (ebib-db-new-database)))
    (add-to-list 'ebib-databases new-db t)
    (ebib-set-database new-db))
  (ebib-db-set-filename (expand-file-name file) ebib-cur-db)
  (setq ebib-log-error nil)             ; we haven't found any errors
  (ebib-log 'log "%s: Opening file %s" (format-time-string "%d %b %Y, %H:%M:%S") (ebib-db-get-filename ebib-cur-db))
  ;; first, we empty the buffers. TODO is that necessary?
  (ebib-erase-buffer ebib-index-buffer)
  (ebib-erase-buffer ebib-entry-buffer)
  (let ((result (ebib-store-bibtex-entries file)))
    (if (not result)
        (ebib-log 'message "(New file)")
      (ebib-db-set-backup t ebib-cur-db)
      (ebib-set-modified nil)
      (setq ebib-cur-keys-list (ebib-db-list-keys ebib-cur-db))
      (ebib-db-set-current-entry-key (car ebib-cur-keys-list) ebib-cur-db)
      ;; fill the buffers. note that filling a buffer also makes that
      ;; buffer active. therefore we do EBIB-FILL-INDEX-BUFFER later.
      ;; TODO is that still correct?
      (ebib-fill-entry-buffer) ; TODO we'll use ebib-display-all below and remove this call here
      (ebib-log 'message "%d entries, %d @STRINGs and %s @PREAMBLE found in file."
                (car result)
                (cadr result)
                (if (cl-caddr result)
                    "a"
                  "no"))))
  ;; add keywords for the new database
  (ebib-keywords-load-keywords ebib-cur-db)
  (if ebib-keywords-files-alist
      (ebib-log 'log "Using keywords from %s." (ebib-keywords-get-file ebib-cur-db))
    (ebib-log 'log "Using general keyword list."))
  ;; fill the index buffer. (this even works if there are no keys
  ;; in the database, for example when the user opened a new file
  ;; or if no BibTeX entries were found.
  (ebib-fill-index-buffer)
  (when ebib-log-error
    (message "%s found! Press `l' to check Ebib log buffer." (nth ebib-log-error '("Warnings" "Errors"))))
  (ebib-log 'log ""))               ; this adds a newline to the log buffer

(defun ebib-merge-bibtex-file ()
  "Merge a BibTeX file into the current database."
  (interactive)
  (if (not ebib-cur-db)
      (error "No database loaded. Use `o' to open a database")
    (let ((file (read-file-name "File to merge: ")))
      (setq ebib-log-error nil)         ; we haven't found any errors
      (let ((result (ebib-store-bibtex-entries file t ebib-uniquify-keys)))
        (when result
          (ebib-log 'log "%s: Merging file %s" (format-time-string "%d-%b-%Y: %H:%M:%S") (expand-file-name file))
          (setq ebib-cur-keys-list (ebib-db-list-keys ebib-cur-db))
          (ebib-db-set-current-entry-key (car ebib-cur-keys-list) ebib-cur-db)
          (ebib-fill-entry-buffer)
          (ebib-fill-index-buffer)
          (ebib-set-modified t)
          (ebib-log 'message "%d entries, %d @STRINGs and %s @PREAMBLE found in file."
                    (car result)
                    (cadr result)
                    (if (cl-caddr result)
                        "a"
                      "no"))))
      (when ebib-log-error
        (message "%s found! Press `l' to check Ebib log buffer." (nth ebib-log-error '("Warnings" "Errors"))))
      (ebib-log 'log ""))))         ; this adds a newline to the log buffer

(defun ebib-store-bibtex-entries (&optional file timestamp uniquify)
  "Read BibTeX entries and store them in EBIB-CUR-DB.
The entries are read from the current buffer or from FILE. If
TIMESTAMP is non-NIL, a timestamp is added to each entry if
EBIB-USE-TIMESTAMP is T. Duplicate entry keys are skipped (and a
warning is logged), unless UNIQUIFY is non-NIL, in which case
duplicate entry keys are made unique.

The return value is a three-element list: the first element is
the number of entries found, the second the number of @STRING
definitions, and the third is T or NIL, indicating whether a
@PREAMBLE was found."
  (let ((n-entries 0)
        (n-strings 0)
        (preamble nil)
        (buffer (current-buffer)))
    (with-temp-buffer
      (with-syntax-table ebib-syntax-table
        (if (and file (file-readable-p file))
            (insert-file-contents file)
          (insert-buffer-substring buffer))
        (goto-char (point-min))
        (while (re-search-forward "^@" nil t) ; find the next entry
          (let ((beg (point)))
            (if (ebib-looking-at-goto-end (concat "\\(" ebib-bibtex-identifier "\\)[[:space:]]*[\(\{]") 1)
                (let ((entry-type (downcase (buffer-substring-no-properties beg (point)))))
                  (ebib-looking-at-goto-end "[[:space:]]*[\(\{]")
                  (cond
                   ((equal entry-type "string") ; string and preamble must be treated differently
                    (if (ebib-read-string)
                        (setq n-strings (1+ n-strings))))
                   ((equal entry-type "preamble")
                    (when (ebib-read-preamble)
                      (setq preamble t)))
                   ((equal entry-type "comment") ; ignore comments
                    (ebib-log 'log "Comment at line %d ignored" (line-number-at-pos))
                    (ebib-match-paren-forward (point-max)))
                   ((assoc entry-type ebib-entry-types) ; if the entry type has been defined
                    (if (ebib-parse-and-store-entry timestamp uniqify)
                        (setq n-entries (1+ n-entries))))
                   ;; anything else we report as an unknown entry type.
                   (t (ebib-log 'warning "Line %d: Unknown entry type `%s'. Skipping." (line-number-at-pos) entry-type)
                      (ebib-match-paren-forward (point-max)))))
              (ebib-log 'error "Error: illegal entry type at line %d. Skipping" (line-number-at-pos)))))
        (list n-entries n-strings preamble)))))

(defun ebib-read-string ()
  "Read the @STRING definition beginning at the line POINT is on.
If a proper abbreviation and string are found, they are stored in
EBIB-CUR-DB. Return the string if one was read, NIL otherwise."
  (let ((limit (save-excursion       ; we find the matching end parenthesis
                 (backward-char)
                 (ebib-match-paren-forward (point-max))
                 (point))))
    (skip-chars-forward "\"#%'(),={} \n\t\f" limit)
    (let ((beg (point)))
      (if (ebib-looking-at-goto-end (concat "\\(" ebib-bibtex-identifier "\\)[ \t\n\f]*=") 1)
        (ebib-ifstring (abbr (buffer-substring-no-properties beg (point)))
            (progn
              (skip-chars-forward "^\"{" limit)
              (let ((beg (point)))
                (ebib-ifstring (string  (if (ebib-match-delim-forward limit)
                                     (buffer-substring-no-properties beg (1+ (point)))
                                   nil))
                    (if (ebib-db-get-string abbr ebib-cur-db 'noerror)
                        (ebib-log 'warning (format "Line %d: @STRING definition `%s' duplicated. Skipping."
                                                   (line-number-at-pos) abbr))
                      (ebib-store-string abbr string))))))
        (ebib-log 'error "Error: illegal string identifier at line %d. Skipping" (line-number-at-pos))))))

(defun ebib-read-preamble ()
  "Read the @PREAMBLE definition at POINT and store it in EBIB-CUR-DB.
If there was already another @PREAMBLE definition, the new one is
added to the existing one with a hash sign `#' between them."
  (let ((beg (point)))
    (forward-char -1)
    (when (ebib-match-paren-forward (point-max))
      (ebib-db-set-preamble (buffer-substring-no-properties beg (point)) ebib-cur-db 'append))))

(defun ebib-parse-and-store-entry (&optional timestamp uniquify)
  "Parse the BibTeX entry at point and store it in EBIB-CUR-DB.
If optional argument TIMESTAMP is non-NIL, add a timestamp to the
entry if EBIB-USE-TIMESTAMP is also set.

The entry is only stored if its key does not already exist in DB,
unless UNIQIFY is non-NIL, in which case the entry key is made
unique. Return the key of the entry if it was successfully
stored, NIL otherwise."
  ;; TODO I need to figure out what happens when the entry key or a field
  ;; name contains illegal symbols and issue appropriate warnings, if possible.
  (beginning-of-line)
  (let* ((entry (bibtex-parse-entry))
         (key (cdr (assoc "=key=" entry))))
    (if (not entry)
        (ebib-log 'error "Error: unknown entry type at line %d. Skipping" (line-number-at-pos))
      (when (and timestamp ebib-use-timestamp)
        (add-to-list 'entry (cons "timestamp" (ebib-db-brace (format-time-string ebib-timestamp-format)))))
      (let ((success (ebib-db-set-entry key (cl-remove "=key=" entry :test #'(lambda (x y)
                                                                               (string= x (car y))))
                                        ebib-cur-db (if uniquify 'uniqify 'noerror))))
        (or success
            (ebib-log 'warning "Line %d: Entry `%s' duplicated. Skipping." (line-number-at-pos) key))))))

(defun ebib-leave-ebib-windows ()
  "Leave the Ebib windows, lowering them if necessary."
  (interactive)
  (ebib-lower t))

(defun ebib-lower (&optional soft)
  "Hide the Ebib windows.
If optional argument SOFT is non-nil, just switch to a non-Ebib
buffer if Ebib is not occupying the entire frame."
  (interactive)
  (unless (member (window-buffer) (list ebib-index-buffer
                                        ebib-entry-buffer
                                        ebib-strings-buffer
                                        ebib-multiline-buffer
                                        ebib-log-buffer))
    (error "Ebib is not active "))
  (if (and soft
           (not (eq ebib-layout 'full)))
      (select-window ebib-pre-ebib-window nil)
    (set-window-configuration ebib-saved-window-config))
  (mapc #'(lambda (buffer)
            (bury-buffer buffer))
        (list ebib-index-buffer
              ebib-entry-buffer
              ebib-strings-buffer
              ebib-multiline-buffer
              ebib-log-buffer)))

(defun ebib-prev-entry ()
  "Move to the previous BibTeX entry."
  (interactive)
  (ebib-execute-when
    ((entries)
     (let ((new-entry (ebib-prev-elem (ebib-cur-entry-key) ebib-cur-keys-list)))
       (if (not new-entry)       ; if the current entry is the first entry,
           (beep)                ; just beep.
         (ebib-db-set-current-entry-key new-entry ebib-cur-db)
         (goto-char (ebib-highlight-start ebib-index-highlight))
         (forward-line -1)
         (ebib-set-index-highlight)
         (ebib-fill-entry-buffer))))
    ((default)
     (beep))))

(defun ebib-next-entry ()
  "Move to the next BibTeX entry."
  (interactive)
  (ebib-execute-when
    ((entries)
     (let ((new-entry (ebib-next-elem (ebib-cur-entry-key) ebib-cur-keys-list)))
       (if (not new-entry)              ; if we're on the last entry,
           (beep)                       ; just beep.
         (ebib-db-set-current-entry-key new-entry ebib-cur-db)
         (goto-char (ebib-highlight-start ebib-index-highlight))
         (forward-line 1)
         (ebib-set-index-highlight)
         (ebib-fill-entry-buffer))))
    ((default)
     (beep))))

(defun ebib-add-entry ()
  "Add a new entry to the database."
  (interactive)
  (ebib-execute-when
    ((database)
     (ebib-ifstring (entry-key (if ebib-autogenerate-keys
                            "<new-entry>"
                          (read-string "New entry key: ")))
         (progn
           (if (and (member entry-key ebib-cur-keys-list)
                    (not ebib-uniquify-keys))
               (error "Key already exists"))
           (with-current-buffer ebib-index-buffer
             ;; we create the alist *before* the call to
             ;; ebib-insert-display-key, because that function refers to the
             ;; it if ebib-index-display-fields is set.
             (let ((fields (list (cons "=type=" ebib-default-type))))
               (ebib-store-entry entry-key fields t t))
             (with-ebib-buffer-writable
               (ebib-insert-sorted entry-key))
             (ebib-set-index-highlight)
             (ebib-db-set-current-entry-key entry-key ebib-cur-db)
             (ebib-fill-entry-buffer)
             (ebib-edit-entry)
             (ebib-set-modified t)))))
    ((no-database)
     (error "No database open. Use `o' to open a database first"))
    ((default)
     (beep))))

(defun ebib-generate-autokey ()
  "Automatically generate a key for the current entry.
This function uses the function BIBTEX-GENERATE-AUTOKEY to
generate the key, see that function's documentation for details."
  (interactive)
  (ebib-execute-when
    ((database entries)
     (let ((new-key
            (with-temp-buffer
              (ebib-format-entry (ebib-cur-entry-key) ebib-cur-db nil)
              (let ((x-ref (ebib-db-get-field-value "crossref" (ebib-cur-entry-key) ebib-cur-db 'noerror 'unbraced)))
                (if x-ref
                    (ebib-format-entry x-ref ebib-cur-db nil)))
              (goto-char (point-min))
              (bibtex-generate-autokey))))
       (if (equal new-key "")
           (error (format "Cannot create key"))
         (ebib-update-keyname new-key))))
    ((default)
     (beep))))

(defun ebib-close-database ()
  "Close the current BibTeX database."
  (interactive)
  (ebib-execute-when
    ((database)
     (when (if (ebib-db-modified-p ebib-cur-db)
               (yes-or-no-p "Database modified. Close it anyway? ")
             (y-or-n-p "Close database? "))
       (ebib-keywords-save-new-keywords ebib-cur-db)
       (let ((next-db (ebib-next-elem ebib-cur-db ebib-databases)))
         (setq ebib-databases (delete ebib-cur-db ebib-databases))
         (if ebib-databases     ; do we still have another database loaded?
             (progn
               (ebib-set-database (or next-db
                                      (ebib-last1 ebib-databases)))
               (unless (ebib-cur-entry-key)
                 (ebib-db-set-current-entry-key (car ebib-cur-keys-list) ebib-cur-db))
               (ebib-fill-entry-buffer)
               (ebib-fill-index-buffer))
           ;; otherwise, we have to clean up a little and empty all the buffers.
           (ebib-set-database nil)
           (mapc #'(lambda (buf) ; this is just to avoid typing almost the same thing three times...
                     (with-current-buffer (car buf)
                       (with-ebib-buffer-writable
                         (erase-buffer))
                       (ebib-delete-highlight (cadr buf))))
                 (list (list ebib-entry-buffer ebib-fields-highlight)
                       (list ebib-index-buffer ebib-index-highlight)
                       (list ebib-strings-buffer ebib-strings-highlight)))
           ;; multiline edit buffer
           (with-current-buffer ebib-multiline-buffer
             (with-ebib-buffer-writable
               (erase-buffer)))
           (with-current-buffer ebib-index-buffer
             (rename-buffer " none")))
         (message "Database closed."))))))

(defun ebib-goto-first-entry ()
  "Move to the first BibTeX entry in the database."
  (interactive)
  (ebib-execute-when
    ((entries)
     (ebib-db-set-current-entry-key (car ebib-cur-keys-list) ebib-cur-db)
     (with-current-buffer ebib-index-buffer
       (goto-char (point-min))
       (ebib-set-index-highlight)
       (ebib-fill-entry-buffer)))
    ((default)
     (beep))))

(defun ebib-goto-last-entry ()
  "Move to the last entry in the BibTeX database."
  (interactive)
  (ebib-execute-when
    ((entries)
     (ebib-db-set-current-entry-key (ebib-last1 ebib-cur-keys-list) ebib-cur-db)
     (with-current-buffer ebib-index-buffer
       (goto-char (point-min))
       (forward-line (1- (length ebib-cur-keys-list)))
       (ebib-set-index-highlight)
       (ebib-fill-entry-buffer)))
    ((default)
     (beep))))

(defun ebib-edit-entry ()
  "Edit the current BibTeX entry."
  (interactive)
  (ebib-execute-when
    ((database entries)
     (setq ebib-cur-entry-fields (ebib-get-all-fields (ebib-db-get-field-value "=type=" (ebib-cur-entry-key) ebib-cur-db)))
     (select-window (get-buffer-window ebib-entry-buffer) nil))
    ((default)
     (beep))))

(defun ebib-edit-keyname ()
  "Change the key of the current BibTeX entry."
  (interactive)
  (ebib-execute-when
    ((database entries)
     (let ((cur-keyname (ebib-cur-entry-key)))
       (ebib-ifstring (new-keyname (read-string (format "Change `%s' to: " cur-keyname)
                                         cur-keyname))
           (ebib-update-keyname new-keyname))))
    ((default)
     (beep))))

(defun ebib-update-keyname (new-key)
  "Change the key of the current BibTeX entry to NEW-KEY."
  (if (and (member new-key ebib-cur-keys-list)
           (not ebib-uniquify-keys))
      (error (format "Key `%s' already exists" new-key)))
  (let ((cur-key (ebib-cur-entry-key)))
    (unless (string= cur-key new-key)
      (let ((fields (ebib-db-get-entry cur-key ebib-cur-db 'noerror))
            (marked (ebib-db-marked-p cur-key ebib-cur-db)))
        (ebib-db-set-entry cur-key nil ebib-cur-db 'overwrite)
        (ebib-remove-key-from-buffer cur-key)
        (ebib-store-entry new-key fields t nil)
        (setq ebib-cur-keys-list (ebib-db-list-keys ebib-cur-db))
        (with-ebib-buffer-writable
          (ebib-insert-sorted new-key))
        (ebib-set-index-highlight)
        (ebib-set-modified t)
        (when marked (ebib-mark-current-entry))))))

(defun ebib-mark/unmark-entry ()
  "Mark or unmark the current entry."
  (interactive)
  (if (ebib-called-with-prefix)
      (ebib-mark/unmark-all-entries)
    (ebib-execute-when
     ((entries)
       (if (ebib-db-marked-p (ebib-cur-entry-key) ebib-cur-db)
           (ebib-unmark-current-entry)
         (ebib-mark-current-entry)))
     ((default)
      (beep)))))

(defun ebib-mark/unmark-all-entries ()
  "Mark or unmark all entries."
  (ebib-execute-when
   ((marked-entries)
    (ebib-db-unmark-entry 'all ebib-cur-db)
    (ebib-fill-index-buffer)
    (message "All entries unmarked"))
   ((entries)
    (ebib-db-mark-entry 'all ebib-cur-db)
    (ebib-fill-index-buffer)
    (message "All entries marked"))
   ((default)
    (beep))))

(defun ebib-unmark-current-entry ()
  "Mark the current entry."
  (ebib-db-unmark-entry (ebib-cur-entry-key) ebib-cur-db)
  (with-current-buffer ebib-index-buffer
    (with-ebib-buffer-writable
      (remove-text-properties (ebib-highlight-start ebib-index-highlight)
                              (ebib-highlight-end ebib-index-highlight)
                              '(face ebib-marked-face)))))

(defun ebib-mark-current-entry ()
  "Unmark the current entry."
  (ebib-db-mark-entry (ebib-cur-entry-key) ebib-cur-db)
  (with-current-buffer ebib-index-buffer
    (with-ebib-buffer-writable
      (add-text-properties (ebib-highlight-start ebib-index-highlight)
                           (ebib-highlight-end ebib-index-highlight)
                           '(face ebib-marked-face)))))

(defun ebib-index-scroll-down ()
  "Move one page up in the database."
  (interactive)
  (ebib-execute-when
    ((entries)
     (scroll-down)
     (ebib-select-entry))
    ((default)
     (beep))))

(defun ebib-index-scroll-up ()
  "Move one page down in the database."
  (interactive)
  (ebib-execute-when
    ((entries)
     (scroll-up)
     (ebib-select-entry))
    ((default)
     (beep))))

(defun ebib-format-entry (key db timestamp)
  "Format entry KEY from database DB into the current buffer in BibTeX format.
If TIMESTAMP is T, a timestamp is added to the entry if
EBIB-USE-TIMESTAMP is T."
  (let ((entry (ebib-db-get-entry key db 'noerror)))
    (when entry
      (insert (format "@%s{%s,\n" (car (assoc "=type=" entry)) key))
      (mapc #'(lambda (elt)
                (let ((key (car elt))
                      (value (cdr elt)))
                  (unless (or (string= key "=type=")
                              (and (string= key "timestamp") timestamp ebib-use-timestamp))
                    (insert (format "\t%s = %s,\n" key value)))))
            entry)
      (if (and timestamp ebib-use-timestamp)
          (insert (format "\ttimestamp = {%s}" (format-time-string ebib-timestamp-format)))
        (delete-char -2))               ; the final ",\n" must be deleted
      (insert "\n}\n\n"))))

(defun ebib-format-strings (db)
  "Format the @STRING commands in database DB."
  (mapc #'(lambda (abbr)
            (let ((@string (ebib-db-get-sting abbr db)))
              (insert (format "@STRING{%s = %s}\n" abbr @string))))
           (ebib-db-list-strings db))
  (insert "\n"))

(defun ebib-compare-xrefs (x y)
  (ebib-db-get-field-value "crossref" x ebib-cur-db 'noerror))

(defun ebib-format-entries (db &optional entries)
  "Write database DB into the current buffer in BibTeX format.
Optional argument ENTRIES is a list of entry keys to be written.
If it is NIL, all entries in DB are written.

The @PREAMBLE and @STRING definitions are always saved."
  (when (ebib-db-get-preamble db)
    (insert (format "@PREAMBLE{%s}\n\n" (ebib-db-get-preamble db))))
  (ebib-format-strings db)
  ;; The list of entries is going to be (destructively) sorted, so we make
  ;; a copy first, because there may be other references to the relevan
  ;; list.
  (let ((sorted-list (copy-tree (or entries
                                    (ebib-db-list-keys db)))))
    (cond
     (ebib-save-xrefs-first
      (setq sorted-list (sort sorted-list 'ebib-compare-xrefs)))
     (ebib-sort-order
      (setq sorted-list (sort sorted-list 'ebib-entry<)))
     (t
      (setq sorted-list (sort sorted-list 'string<))))
    (mapc #'(lambda (key) (ebib-format-entry key db nil)) sorted-list)))

(defun ebib-make-backup (file)
  "Create a backup of FILE.
Honour EBIB-CREATE-BACKUPS and BACKUP-DIRECTORY-ALIST."
  (when ebib-create-backups
    (let ((backup-file (make-backup-file-name file)))
      (if (file-writable-p backup-file)
          (copy-file file backup-file t)
        (ebib-log 'error "Could not create backup file `%s'" backup-file)))))

(defun ebib-save-database (db)
  "Save database DB."
  (when (and (ebib-db-backup-p db)
             (file-exists-p (ebib-db-get-filename db)))
    (ebib-make-backup (ebib-db-get-filename db))
    (ebib-db-set-backup nil db))
  (with-temp-buffer
    (ebib-format-entries db)
    (write-region (point-min) (point-max) (ebib-db-get-filename db)))
  (if (eq db ebib-cur-db)
      (ebib-set-modified nil) ; this also sets the modified flag of the index buffer
    (ebib-db-set-modified nil db)))

(defun ebib-write-database ()
  "Write the current database to a different file.
If a filter is active, only the visible entries (i.e., those
matching the filter) are written and the filename of the current
database is not changed. Otherwise the new file becomes
associated with the current database."
  (interactive)
  (ebib-execute-when
    ((database)
     (ebib-ifstring (new-filename (expand-file-name (read-file-name "Save to file: " "~/")))
         (progn
           (with-temp-buffer
             (ebib-format-entries ebib-cur-db ebib-cur-keys-list)
             (ebib-write-region-safely (point-min) (point-max) new-filename nil nil nil t))
           ;; if EBIB-WRITE-REGION-SAFELY was cancelled by the user because
           ;; s/he didn't want to overwrite an already existing file, it
           ;; throws an error, so we can safely set the new filename here.
           (unless (ebib-db-get-filter ebib-cur-db)
             (ebib-db-set-filename new-filename ebib-cur-db 'overwrite)
             (rename-buffer (concat (format " %d:" (1+ (- (length ebib-databases)
                                                          (length (member ebib-cur-db ebib-databases)))))
                                    (file-name-nondirectory (ebib-db-get-filename ebib-cur-db))))))))
    ((default)
     (beep))))

(defun ebib-save-current-database ()
  "Save the current database."
  (interactive)
  (ebib-execute-when
    ((database)
     (if (not (ebib-db-modified-p ebib-cur-db))
         (message "No changes need to be saved.")
       (ebib-save-database ebib-cur-db)))
    ((default)
     (beep))))

(defun ebib-save-all-databases ()
  "Save all currently open databases if they were modified."
  (interactive)
  (mapc #'(lambda (db)
            (when (ebib-db-modified-p db)
              (ebib-save-database db)))
        ebib-databases)
  (message "All databases saved."))

;; the exporting functions will have to be redesigned completely. for now (1 Feb
;; 2012) we just define a new function ebib-export-entries. in the long run,
;; this should be the general exporting function, calling other functions as the
;; need arises.

(defun ebib-export-entries (entries &optional source-db filename)
  "Export ENTRIES.
ENTRIES is a list of entry keys. Optional argument SOURCE-DB is
the database from which the entries are exported; it defaults to
the current database. If FILENAME is not provided, the
user is asked for one."
  (unless filename
    (setq filename (read-file-name
                    "File to export entries to:" "~/" nil nil ebib-export-filename)))
  (unless source-db
    (setq source-db ebib-cur-db))
  (with-temp-buffer
    (insert "\n")
    (mapc #'(lambda (key)
              (ebib-format-entry key source-db nil))
          entries)
    (append-to-file (point-min) (point-max) filename)
    (setq ebib-export-filename filename)))

;; TODO why not create a function that displays some more information about
;; the current database?
(defun ebib-print-filename ()
  "Display the filename of the current database in the minibuffer."
  (interactive)
  (message (ebib-db-get-filename ebib-cur-db)))

(defun ebib-follow-crossref ()
  "Follow the crossref field and jump to that entry.
If the current entry's crossref field is empty, search for the
first entry with the current entry's key in its crossref field."
  (interactive)
  (let ((new-key (ebib-db-get-field-value "crossref" (ebib-cur-entry-key) ebib-cur-db 'noerror 'unbraced)))
    (if (and new-key
             (member new-key ebib-cur-keys-list))
        (progn
          (ebib-db-set-current-entry-key new-key ebib-cur-db)
          (ebib-fill-entry-buffer)
          (ebib-fill-index-buffer)) ; TODO why do we fill the index buffer here?
      (setq ebib-search-string (ebib-cur-entry-key))
      (ebib-search-next))))

(defun ebib-toggle-hidden ()
  "Toggle viewing hidden fields."
  (interactive)
  (setq ebib-hide-hidden-fields (not ebib-hide-hidden-fields))
  (ebib-fill-entry-buffer))

(defun ebib-toggle-timestamp ()
  "Toggle using timestamp for new entries."
  (interactive)
  (setq ebib-use-timestamp (not ebib-use-timestamp)))

(defun ebib-toggle-xrefs-first ()
  "Toggle saving of crossreferenced entries first."
  (interactive)
  (setq ebib-save-xrefs-first (not ebib-save-xrefs-first)))

(defun ebib-toggle-identical-fields ()
  "Toggle whether Ebib allows identical fields when opening a .bib file."
  (interactive)
  (setq ebib-allow-identical-fields (not ebib-allow-identical-fields)))

(defun ebib-toggle-layout ()
  "Toggle the Ebib layout."
  (interactive)
  (if (eq ebib-layout 'full)
      (setq ebib-layout 'custom)
    (setq ebib-layout 'full))
  (ebib-lower)
  (ebib))

(defun ebib-toggle-print-newpage ()
  "Toggle whether index cards are printed with a newpage after each card."
  (interactive)
  (setq ebib-print-newpage (not ebib-print-newpage)))

(defun ebib-toggle-print-multiline ()
  "Toggle whether multiline fields are printed."
  (interactive)
  (setq ebib-print-multiline (not ebib-print-multiline)))

(defun ebib-delete-entry ()
  "Delete the current entry from the database.
With prefix key, delete all marked entries."
  (interactive)
  (if (ebib-called-with-prefix)
      (ebib-execute-when
        ((database marked-entries)
         (when (y-or-n-p "Delete all marked entries? ")
           (mapc #'(lambda (entry)
                     (ebib-remove-entry entry (not (string= entry (ebib-cur-entry-key)))))
                 (ebib-db-marked-entry-list ebib-cur-db))
           (message "Marked entries deleted.")
           (ebib-set-modified t)
           (ebib-fill-entry-buffer)
           (ebib-fill-index-buffer)))
        ((default)
         (beep)))
    (ebib-execute-when
      ((database entries)
       (let ((cur-entry (ebib-cur-entry-key)))
         (when (y-or-n-p (format "Delete %s? " cur-entry))
           (ebib-remove-entry cur-entry)
           (ebib-remove-key-from-buffer cur-entry)
           (ebib-fill-entry-buffer)
           (ebib-set-modified t)
           (message (format "Entry `%s' deleted." cur-entry)))))
      ((default)
       (beep)))))

(defun ebib-remove-entry (entry-key &optional new-cur-entry)
  "Remove ENTRY-KEY from the current database.
Optional argument NEW-CUR-ENTRY is the key of the entry that is
to become the new current entry. It it is NIL, the entry after
the deleted one becomes the new current entry. If it is T, the
current entry is not changed."
  (ebib-db-set-entry entry-key nil ebib-cur-db 'overwrite)
  (cond
   ((null new-cur-entry) (setq new-cur-entry (or (ebib-next-elem (ebib-cur-entry-key) ebib-cur-keys-list)
                                                 (ebib-last1 ebib-cur-keys-list))))
   ((stringp new-cur-entry) t)
   (t (setq new-cur-entry (ebib-cur-entry-key))))
  (setq ebib-cur-keys-list (delete entry-key ebib-cur-keys-list))
  (ebib-db-unmark-entry entry-key ebib-cur-db) ; we can do this even though the entry has already been removed from the database
  (ebib-db-set-current-entry-key new-cur-entry))

(defun ebib-remove-key-from-buffer (entry-key)
  "Remove ENTRY-KEY from the index buffer and highlights the current entry."
  (with-ebib-buffer-writable
    (let ((beg (ebib-search-key-in-buffer entry-key)))
      (forward-line 1)
      (delete-region beg (point))))
  (ebib-execute-when
    ((entries)
     (ebib-search-key-in-buffer (ebib-cur-entry-key))
     (ebib-set-index-highlight))))

(defun ebib-select-entry ()
  "Make the entry at POINT the current entry."
  (interactive)
  (ebib-execute-when
    ((entries)
     (beginning-of-line)
     (let ((beg (point)))
       (let* ((key (save-excursion
                     (skip-chars-forward "^ ")
                     (buffer-substring-no-properties beg (point))))
              (new-cur-entry (car (member key ebib-cur-keys-list))))
         (when new-cur-entry
           (ebib-db-set-current-entry-key new-cur-entry ebib-cur-db)
           (ebib-set-index-highlight)
           (ebib-fill-entry-buffer)))))
    ((default)
     (beep))))

(defun ebib-search ()
  "Search the current database.
The search is conducted with STRING-MATCH and can therefore be a
regexp. Searching starts with the current entry."
  (interactive)
  (ebib-execute-when
    ((entries)
     (ebib-ifstring (search-str (read-string "Search database for: "))
         (progn
           (setq ebib-search-string search-str)
           ;; first we search the current entry
           (if (ebib-search-in-entry ebib-search-string
                                     (ebib-db-get-entry (ebib-cur-entry-key) ebib-cur-db 'noerror))
               (ebib-fill-entry-buffer ebib-search-string)
             ;; if the search string wasn't found in the current entry, we continue searching.
             (ebib-search-next)))))
    ((default)
     (beep))))

(defun ebib-search-next ()
  "Search the next occurrence of EBIB-SEARCH-STRING.
Searching starts at the entry following the current entry. If a
match is found, the matching entry is shown and becomes the new
current entry."
  (interactive)
  (ebib-execute-when
    ((entries)
     (if (null ebib-search-string)
         (message "No search string")
       (let (cur-search-entry)
         (while (and (setq cur-search-entry (ebib-next-elem (ebib-cur-entry-key) ebib-cur-keys-list))
                     (null (ebib-search-in-entry ebib-search-string
                                                 (ebib-db-get-entry cur-search-entry ebib-cur-db)))))
         (if (null cur-search-entry)
             (message (format "`%s' not found" ebib-search-string))
           (ebib-db-set-current-entry-key cur-search-entry ebib-cur-db)
           (with-current-buffer ebib-index-buffer
             (goto-char (point-min))
             (re-search-forward (format "^%s " (ebib-cur-entry-key)))
             (beginning-of-line)
             (ebib-set-index-highlight)
             (ebib-fill-entry-buffer ebib-search-string))))))
    ((default)
     (beep))))

(defun ebib-search-in-entry (search-str entry &optional field)
  "Search one entry of the current database.
Return a list of fields in ENTRY that match the regexp
SEARCH-STR, or NIL if no matches were found. If FIELD is given,
only that field is searched."
  (let ((case-fold-search t)  ; we want to ensure a case-insensitive search
        (result nil))
    (when field
      (setq entry (assoc field entry)))
    (mapc #'(lambda (elt)
              (when (and (not (string= (car elt) "=type=")) ; we do not want to match the entry type
                         (string-match search-str (cdr elt)))
                (setq result (cons (car elt) result))))
          entry)
    result))

(defun ebib-edit-strings ()
  "Edit the @STRING definitions in the database."
  (interactive)
  (ebib-execute-when
    ((database)
     (setq ebib-cur-strings-list (ebib-db-list-strings ebib-cur-db))
     (ebib-fill-strings-buffer)
     (select-window (get-buffer-window ebib-entry-buffer) nil)
     (set-window-dedicated-p (selected-window) nil)
     (switch-to-buffer ebib-strings-buffer)
     (unless (eq ebib-layout 'full)
       (set-window-dedicated-p (selected-window) t))
     (goto-char (point-min)))
    ((default)
     (beep))))

(defun ebib-edit-preamble ()
  "Edit the @PREAMBLE definition in the database."
  (interactive)
  (ebib-execute-when
    ((database)
     (select-window (ebib-temp-window) nil)
     (ebib-multiline-edit 'preamble (ebib-db-get-preamble ebib-cur-db)))
    ((default)
     (beep))))

(defun ebib-print-entries ()
  "Create a LaTeX file with entries from the current database.
Either prints the entire database, or the marked entries."
  (interactive)
  (ebib-execute-when
    ((entries)
     (let ((entries (or (when (or (ebib-called-with-prefix)
                                  (equal '(menu-bar) (elt (this-command-keys-vector) 0)))
                          (ebib-db-get-marked-entries ebib-cur-db))
                        ebib-cur-keys-list)))
       (ebib-ifstring (tempfile (if (not (string= "" ebib-print-tempfile))
                             ebib-print-tempfile
                           (read-file-name "Use temp file: " "~/" nil nil)))
           (progn
             (with-temp-buffer
               (insert "\\documentclass{article}\n\n")
               (when ebib-print-preamble
                 (mapc #'(lambda (string)
                           (insert (format "%s\n" string)))
                       ebib-print-preamble))
               (insert "\n\\begin{document}\n\n")
               (mapc #'(lambda (entry-key)
                         (insert "\\begin{tabular}{p{0.2\\textwidth}p{0.8\\textwidth}}\n")
                         (let ((entry (ebib-db-get-entry entry-key ebib-cur-db 'noerror)))
                           (insert (format "\\multicolumn{2}{l}{\\texttt{%s (%s)}}\\\\\n"
                                           entry-key (cdr (assoc "=type=" entry))))
                           (insert "\\hline\n")
                           (mapc #'(lambda (field)
                                     (ebib-ifstring (value (car (assoc field entry)))
                                         (when (or (not (ebib-multiline-p value))
                                                   ebib-print-multiline)
                                           (insert (format "%s: & %s\\\\\n"
                                                           field (ebib-db-unbrace value))))))
                                 (cdr (ebib-get-all-fields (cdr (assoc "=type=" entry))))))
                         (insert "\\end{tabular}\n\n")
                         (insert (if ebib-print-newpage
                                     "\\newpage\n\n"
                                   "\\bigskip\n\n")))
                     entries)
               (insert "\\end{document}\n")
               (write-region (point-min) (point-max) tempfile))
             (ebib-lower)
             (find-file tempfile)))))
    ((default)
     (beep))))

(defun ebib-latex-entries ()
  "Create a LaTeX file that \\nocites entries from the current database.
Operates either on all entries or on the marked entries."
  (interactive)
  (ebib-execute-when
    ((database entries)
     (ebib-ifstring (tempfile (if (not (string= "" ebib-print-tempfile))
                           ebib-print-tempfile
                         (read-file-name "Use temp file: " "~/" nil nil)))
         (progn
           (with-temp-buffer
             (insert "\\documentclass{article}\n\n")
             (when ebib-print-preamble
               (mapc #'(lambda (string)
                         (insert (format "%s\n" string)))
                     ebib-latex-preamble))
             (insert "\n\\begin{document}\n\n")
             (if (and (or (ebib-called-with-prefix)
                          (equal '(menu-bar) (elt (this-command-keys-vector) 0)))
                      (ebib-db-get-marked-entries ebib-cur-db))
                 (mapc #'(lambda (entry)
                           (insert (format "\\nocite{%s}\n" entry)))
                       (ebib-db-get-marked-entries ebib-cur-db))
               (insert "\\nocite{*}\n"))
             (insert (format "\n\\bibliography{%s}\n\n" (expand-file-name (ebib-db-get-filename ebib-cur-db))))
             (insert "\\end{document}\n")
             (write-region (point-min) (point-max) tempfile))
           (ebib-lower)
           (find-file tempfile))))
    ((default)
     (beep))))

(defun ebib-set-database (db &optional update-display)
  "Make DB the current database.
If UPDATE-DISPLAY is set, the index and entry buffers are
redisplayed. DB may also be NIL, if no database is open."
  (setq ebib-cur-db db)
  (when db
    (setq ebib-cur-keys-list (ebib-db-list-keys db)))
  (when update-display
    (ebib-fill-entry-buffer)
    (ebib-fill-index-buffer)))

(defun ebib-switch-to-database (num)
  "Switch to database NUM."
  (interactive "NSwitch to database number: ")
  (let ((new-db (nth (1- num) ebib-databases)))
    (if new-db
        (ebib-set-database new-db)
      (error "Database %d does not exist" num))))

(defun ebib-next-database ()
  "Switch to the next database."
  (interactive)
  (ebib-execute-when
    ((database)
     (ebib-set-database (or (ebib-next-elem ebib-cur-db ebib-databases)
                            (car ebib-databases))
                        t))))

(defun ebib-prev-database ()
  "Switch to the previous database."
  (interactive)
  (ebib-execute-when
    ((database)
     (ebib-set-database (or (ebib-prev-elem ebib-cur-db ebib-databases)
                            (ebib-last1 ebib-databases))
                        t))))

(defun ebib-select-url (n urls)
  "Return the Nth URL in URLS.
URLs are split using EBIB-REGEXP-URL. The URL is cleaned up a bit
before being returned, i.e., an enclosing \\url{...} or <...> is
removed."
  (let ((url (nth (1- n)
                  (let ((start 0)
                        (result nil))
                    (while (string-match ebib-url-regexp urls start)
                      (add-to-list 'result (match-string 0 urls) t)
                      (setq start (match-end 0)))
                    result))))
    (if url
        (cond
         ;; first see if the url is contained in \url{...}
         ((string-match "\\\\url{\\(.*?\\)}" url)
          (setq url (match-string 1 url)))
         ;; then check for http(s), or whatever the user customized
         ((string-match ebib-url-regexp url)
          (setq url (match-string 0 url)))
         ;; this clause probably won't be reached, but just in case
         (t (error "Not a URL: `%s'" url)))
      ;; otherwise, we didn't find a url
      (error "No URL found in `%s'" urls))
    url))

(defun ebib-browse-url (num)
  "Open the URL in the standard URL field in a browser.
The standard URL field (see user option EBIB-STANDARD-URL-FIELD)
may contain more than one URL, if they're whitespace-separated.
In that case, a numeric prefix argument can be used to specify
which URL to choose."
  (interactive "p")
  (ebib-execute-when
    ((entries)
     (let ((urls (car (ebib-db-get-field-value ebib-standard-url-field
                                               (ebib-cur-entry-key)
                                               ebib-cur-db 'noerror 'unbraced 'xref))))
       (if urls
           (ebib-call-browser (ebib-select-url num urls))
         (error "Field `%s' is empty" ebib-standard-url-field))))
    ((default)
     (beep))))

(defun ebib-browse-doi ()
  "Open the DOI in the standard DOI field in a browser.
The stardard DOI field (see user option EBIB-STANDARD-DOI-FIELD)
may contain only one DOI.

The DOI is combined with the value of EBIB-DOI-URL before being
sent to the browser."
  (interactive)
  (ebib-execute-when
   ((entries)
    (let ((doi (car (ebib-db-get-field-value ebib-standard-doi-field
                                             (ebib-cur-entry-key)
                                             ebib-cur-db 'noerror 'unbraced 'xref))))
      (if doi
          (ebib-call-browser (format ebib-doi-url doi))
        (error "No DOI found in field `%s'" ebib-standard-doi-field))))
   ((default)
    (beep))))

(defun ebib-call-browser (url)
  "Pass URL to a browser."
  (if (string= ebib-browser-command "")
      (progn
        (message "Calling BROWSE-URL on `%s'" url)
        (browse-url url))
    (message "Executing `%s %s'" ebib-browser-command url)
    (start-process "Ebib-browser" nil ebib-browser-command url)))

(defun ebib-view-file (num)
  "View a file in the standard file field.
The standard file field (see option EBIB-STANDARD-FILE-FIELD) may
contain more than one filename if they're whitespace-separated.
In that case, a numeric prefix argument can be used to specify
which file to choose."
  (interactive "p")
  (ebib-execute-when
    ((entries)
     (let ((files (car (ebib-db-get-field-value ebib-standard-file-field
                                                (ebib-cur-entry-key)
                                                ebib-cur-db 'noerror 'unbraced 'xref))))
       (if files
           (ebib-call-file-viewer files num)
         (error "Field `%s' is empty" ebib-standard-file-field))))
    ((default)
     (beep))))

(defun ebib-call-file-viewer (files n)
  "Pass the Nth file in FILES to an external viewer.
FILES must be a string of whitespace-separated filenames.

The external viewer to use is selected from
EBIB-FILE-ASSOCIATIONS on the basis of the file extension."
  (let* ((file (nth (1- n)
                    (let ((start 0)
                          (result nil))
                      (while (string-match ebib-file-regexp files start)
                        (add-to-list 'result (match-string 0 files) t)
                        (setq start (match-end 0)))
                      result)))
         (ext (file-name-extension file)))
    (let ((file-full-path (or
                           (locate-file file ebib-file-search-dirs)
                           (locate-file (file-name-nondirectory file) ebib-file-search-dirs))))
      (if file-full-path
          (ebib-ifstring (viewer (cdr (assoc ext ebib-file-associations)))
              (progn
                (message "Executing `%s %s'" viewer file-full-path)
                (start-process (concat "ebib " ext " viewer process") nil viewer file-full-path))
            (message "Opening `%s'" file-full-path)
            (ebib-lower)
            (find-file file-full-path))
        (error "File not found: `%s'" file)))))

(defun ebib-filter-db-and (not)
  "Filter entries in the current database.
If the current database is filtered already, perform a logical
AND on the filter."
  (interactive "p")
  (ebib-execute-when
    ((entries)
     (ebib-filter-db 'and not))
    ((default)
     (beep))))

(defun ebib-filter-db-or (not)
  "Filter entries in the current database.
If the current database is filtered already, perform a logical OR
on the filter."
  (interactive "p")
  (ebib-execute-when
    ((entries)
     (ebib-filter-db 'or not))
    ((default)
     (beep))))

(defun ebib-filter-db-not ()
  "Perform a logical negation on the current filter."
  (interactive)
  (ebib-execute-when
    ((entries)
     (let ((filter (ebib-db-get-filter ebib-cur-db)))
       (setq filter (if (eq (car filter) 'not)
                        (cadr filter)
                      `(not ,filter)))
       (ebib-db-set-filter filter ebib-cur-db)
       (ebib-fill-entry-buffer)
       (ebib-fill-index-buffer)))
    ((default)
     (beep))))

(defun ebib-filter-db (bool not)
  "Filter the current database.
BOOL is the operator to be used, either `and' or `or'. If NOT<0,
a logical `not' is applied to the selection."
  (ebib-execute-when
    ((database)
     (let* ((field (completing-read (format "Filter: %s(contains <field> <regexp>)%s. Enter field: "
                                            (if (< not 0) "(not " "")
                                            (if (< not 0) ")" ""))
                                    (cons '("any" 0)
                                          (mapcar #'(lambda (x)
                                                      (cons x 0))
                                                  (append ebib-unique-field-list ebib-additional-fields)))
                                    nil t))
            (regexp (read-string (format "Filter: %s(contains %s <regexp>)%s. Enter regexp: "
                                         (if (< not 0) "(not " "")
                                         field
                                         (if (< not 0) ")" ""))))
            (new-clause (if (>= not 0)
                            `(contains ,field ,regexp)
                          `(not (contains ,field ,regexp))))
            (filter (ebib-db-get-filter ebib-cur-db)))
       (ebib-db-set-filter (if filter
                               `(,bool ,filter ,new-clause)
                             new-clause)
                           ebib-cur-db))
     (ebib-fill-index-buffer)
     (ebib-fill-entry-buffer))
    ((default)
     (beep))))

(defun ebib-print-filter ()
  "Display the filter of the current database."
  (interactive "P")
  (ebib-execute-when
    ((database)
     (message "%S" (ebib-db-get-filter ebib-cur-db)))
    ((default)
     (beep))))

(defun ebib-delete-filter ()
  "Delete the filter on the current database."
  (ebib-db-set-filter nil ebib-cur-db)
  (ebib-fill-entry-buffer)
  (ebib-fill-index-buffer))

(defun ebib-show-log ()
  "Display the contents of the log buffer."
  (interactive)
  (select-window (get-buffer-window ebib-entry-buffer) nil)
  (set-window-dedicated-p (selected-window) nil)
  (switch-to-buffer ebib-log-buffer)
  (unless (eq ebib-layout 'full)
    (set-window-dedicated-p (selected-window) t)))

(defun ebib-create-citation-command (format-string &optional key)
  "Create a citation command using FORMAT-STRING.
If FORMAT-STRING contains a %K directive, it is replaced with
KEY. Furthermore, FORMAT-STRING may contain any number of %A
directives for additional arguments to the citation. The user is
asked to supply a string for each of them, which may be empty.

Each %A directive may be wrapped in a %<...%> pair, containing
optional material both before and after %A. If the user supplies
an empty string for such an argument, the optional material
surrounding it is not included in the citation command."
  (when (and (string-match "%K" format-string)
             key)
    (setq format-string (replace-match key t t format-string)))
  (loop for n = 1 then (1+ n)
        until (null (string-match "%<\\(.*?\\)%A\\(.*?\\)%>\\|%A" format-string)) do
        (setq format-string (replace-match (ebib-ifstring (argument (save-match-data
                                                               (read-from-minibuffer (format "Argument %s%s: " n (if key
                                                                                                                     (concat " for " key)
                                                                                                                   "")))))
                                               (concat "\\1" argument "\\2")
                                             "")
                                           t nil format-string))
        finally return format-string))

(defun ebib-split-citation-string (format-string)
  "Split up FORMAT-STRING.
The return value is a list of (BEFORE REPEATER SEPARATOR AFTER),
where BEFORE is the part before the repeating part of
FORMAT-STRING, REPEATER the repeating part, SEPARATOR the string
to be placed between each instance of REPEATER and AFTER the part
after the last instance of REPEATER."
  (let (before repeater separator after)
    ;; first check if the format string has a repeater and if so, separate each component
    (cond
     ((string-match "\\(.*?\\)%(\\(.*\\)%\\(.*?\\))\\(.*\\)" format-string)
      (setq before (match-string 1 format-string)
            repeater (match-string 2 format-string)
            separator (match-string 3 format-string)
            after (match-string 4 format-string)))
     ((string-match "\\(.*?\\)\\(%K\\)\\(.*\\)" format-string)
      (setq before (match-string 1 format-string)
            repeater (match-string 2 format-string)
            after (match-string 3 format-string))))
    (values before repeater separator after)))

(defun ebib-push-bibtex-key ()
  "Push the current entry to a LaTeX buffer.
The user is prompted for the buffer to push the entry into."
  (interactive)
  (let ((called-with-prefix (ebib-called-with-prefix)))
    (ebib-execute-when
      ((entries)
       (let ((buffer (read-buffer (if called-with-prefix
                                      "Push marked entries to buffer: "
                                    "Push entry to buffer: ")
                                  ebib-push-buffer t)))
         (when buffer
           (setq ebib-push-buffer buffer)
           (let* ((format-list (or (cadr (assoc (buffer-local-value 'major-mode (get-buffer buffer)) ebib-citation-commands))
                                   (cadr (assoc 'any ebib-citation-commands))))
                  (citation-command
                   (ebib-ifstring (format-string (cadr (assoc
                                                 (completing-read "Command to use: " format-list nil nil nil ebib-minibuf-hist)
                                                 format-list)))
                       (cl-multiple-value-bind (before repeater separator after) (ebib-split-citation-string format-string)
                         (cond
                          ((and called-with-prefix ; if there are marked entries and the user wants to push those
                                (ebib-db-marked-entry-list ebib-cur-db))
                           (concat (ebib-create-citation-command before)
                                   (mapconcat #'(lambda (key) ; then deal with the entries one by one
                                                  (ebib-create-citation-command repeater key))
                                              (ebib-db-marked-entry-list ebib-cur-db)
                                              (if separator separator (read-from-minibuffer "Separator: ")))
                                   (ebib-create-citation-command after)))
                          (t        ; otherwise just take the current entry
                           (ebib-create-citation-command (concat before repeater after) (ebib-cur-entry-key)))))
                     (if (ebib-db-marked-entry-list ebib-cur-db) ; if the user doesn't provide a command
                         (mapconcat #'(lambda (key) ; we just insert the entry key or keys
                                        key)
                                    (ebib-db-marked-entry-list ebib-cur-db)
                                    (read-from-minibuffer "Separator: "))
                       (ebib-cur-entry-key)))))
             (when citation-command
               (with-current-buffer buffer
                 (insert citation-command))
               (message "Pushed entries to buffer %s" buffer))))))
      ((default)
       (beep)))))

(defun ebib-index-help ()
  "Show the info node of Ebib's index buffer."
  (interactive)
  (setq ebib-info-flag t)
  (ebib-lower)
  (info "(ebib) The Index Buffer"))

(defun ebib-info ()
  "Show Ebib's info node."
  (interactive)
  (setq ebib-info-flag t)
  (ebib-lower)
  (info "(ebib)"))

;;;;;;;;;;;;;;;;
;; entry-mode ;;
;;;;;;;;;;;;;;;;

(defvar ebib-entry-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map)
    (define-key map [up] 'ebib-prev-field)
    (define-key map [down] 'ebib-next-field)
    (define-key map [prior] 'ebib-goto-prev-set)
    (define-key map [next] 'ebib-goto-next-set)
    (define-key map [home] 'ebib-goto-first-field)
    (define-key map [end] 'ebib-goto-last-field)
    (define-key map [return] 'ebib-edit-field)
    (define-key map " " 'ebib-goto-next-set)
    (define-key map "b" 'ebib-goto-prev-set)
    (define-key map "c" 'ebib-copy-field-contents)
    (define-key map "d" 'ebib-delete-field-contents)
    (define-key map "e" 'ebib-edit-field)
    (define-key map "f" 'ebib-view-file-in-field)
    (define-key map "g" 'ebib-goto-first-field)
    (define-key map "G" 'ebib-goto-last-field)
    (define-key map "h" 'ebib-entry-help)
    (define-key map "j" 'ebib-next-field)
    (define-key map "k" 'ebib-prev-field)
    (define-key map "l" 'ebib-edit-multiline-field)
    (define-key map [(control n)] 'ebib-next-field)
    (define-key map [(meta n)] 'ebib-goto-prev-set)
    (define-key map [(control p)] 'ebib-prev-field)
    (define-key map [(meta p)] 'ebib-goto-next-set)
    (define-key map "q" 'ebib-quit-entry-buffer)
    (define-key map "r" 'ebib-toggle-braced)
    (define-key map "s" 'ebib-insert-abbreviation)
    (define-key map "u" 'ebib-browse-url-in-field)
    (define-key map "x" 'ebib-cut-field-contents)
    (define-key map "\C-xb" 'undefined)
    (define-key map "\C-xk" 'undefined)
    (define-key map "y" 'ebib-yank-field-contents)
    map)
  "Keymap for the Ebib entry buffer.")

(define-derived-mode ebib-entry-mode
  fundamental-mode "Ebib-entry"
  "Major mode for the Ebib entry buffer."
  (setq buffer-read-only t)
  (setq truncate-lines t))

(defun ebib-quit-entry-buffer ()
  "Quit editing the entry.
If the key of the current entry is <new-entry>, a new key is
automatically generated using BIBTEX-GENERATE-AUTOKEY."
  (interactive)
  (select-window (get-buffer-window ebib-index-buffer) nil)
  (if (equal (ebib-cur-entry-key) "<new-entry>")
      (ebib-generate-autokey)))

(defun ebib-find-visible-field (field direction)
  "Find the first visible field before or after FIELD.
If DIRECTION is negative, search the preceding fields, otherwise
search the succeeding fields. If FIELD is visible itself, return
that. If there is no preceding/following visible field, return
NIL. If EBIB-HIDE-HIDDEN-FIELDS is NIL, return FIELD."
  (when ebib-hide-hidden-fields
    (let ((fn (if (>= direction 0)
                  'ebib-next-elem
                'ebib-prev-elem)))
      (while (and field
                  (member field ebib-hidden-fields))
        (setq field (funcall fn field ebib-cur-entry-fields)))))
  field)

(defun ebib-prev-field ()
  "Move to the previous field."
  (interactive)
  (let ((new-field (ebib-find-visible-field (ebib-prev-elem ebib-current-field ebib-cur-entry-fields) -1)))
    (if (null new-field)
        (beep)
      (setq ebib-current-field new-field)
      (ebib-move-to-current-field -1))))

(defun ebib-next-field (&optional interactive)
  "Move to the next field."
  (interactive "p")
  (let ((new-field (ebib-find-visible-field (ebib-next-elem ebib-current-field ebib-cur-entry-fields) 1)))
    (if (null new-field)
        (when interactive ; this function is called after editing a field, and we don't want a beep then
          (beep))
      (setq ebib-current-field new-field)
      (ebib-move-to-current-field 1))))

(defun ebib-goto-first-field ()
  "Move to the first field."
  (interactive)
  (let ((new-field (ebib-find-visible-field (car ebib-cur-entry-fields) 1)))
    (if (null new-field)
        (beep)
      (setq ebib-current-field new-field)
      (ebib-move-to-current-field -1))))

(defun ebib-goto-last-field ()
  "Move to the last field."
  (interactive)
  (let ((new-field (ebib-find-visible-field (ebib-last1 ebib-cur-entry-fields) -1)))
    (if (null new-field)
        (beep)
      (setq ebib-current-field new-field)
      (ebib-move-to-current-field 1))))

(defun ebib-goto-next-set ()
  "Move to the next set of fields."
  (interactive)
  (cond
   ((string= ebib-current-field "=type=") (ebib-next-field))
   ((member ebib-current-field ebib-additional-fields) (ebib-goto-last-field))
   (t (let* ((entry-type (ebib-db-get-field-value "=type=" (ebib-cur-entry-key) ebib-cur-db))
             (obl-fields (ebib-get-obl-fields entry-type))
             (opt-fields (ebib-get-opt-fields entry-type))
             (new-field nil))
        (when (member ebib-current-field obl-fields)
          (setq new-field (ebib-find-visible-field (car opt-fields) 1)))
        ;; new-field is nil if there are no opt-fields
        (when (or (member ebib-current-field opt-fields)
                  (null new-field))
          (setq new-field (ebib-find-visible-field (car ebib-additional-fields) 1)))
        (if (null new-field)
            ;; if there was no further set to go to, go to the last field
            ;; of the current set
            (ebib-goto-last-field)
          (setq ebib-current-field new-field)
          (ebib-move-to-current-field 1))))))

(defun ebib-goto-prev-set ()
  "Move to the previous set of fields."
  (interactive)
  (unless (string= ebib-current-field "=type=")
    (let* ((entry-type (ebib-db-get-field-value "=type=" (ebib-cur-entry-key) ebib-cur-db))
           (obl-fields (ebib-get-obl-fields entry-type))
           (opt-fields (ebib-get-opt-fields entry-type))
           (new-field nil))
      (if (member ebib-current-field obl-fields)
          (ebib-goto-first-field)
        (when (member ebib-current-field ebib-additional-fields)
          (setq new-field (ebib-find-visible-field (ebib-last1 opt-fields) -1)))
        (when (or (member ebib-current-field opt-fields)
                  (null new-field))
          (setq new-field (ebib-find-visible-field (ebib-last1 obl-fields) -1)))
        (if (null new-field)
            (ebib-goto-first-field)
          (setq ebib-current-field new-field)
          (ebib-move-to-current-field -1))))))

;; the following edit functions make use of completion. since we don't want
;; the completion buffer to be shown in the index window, we need to switch
;; focus to an appropriate window first. we do this in an unwind-protect to
;; make sure we always get back to the entry buffer.

(defun ebib-edit-entry-type ()
  "Edit the entry type."
  (unwind-protect
      (progn
        (if (eq ebib-layout 'full)
            (other-window 1)
          (select-window ebib-pre-ebib-window) nil)
        (ebib-ifstring (new-type (completing-read "type: " ebib-entry-types nil t))
            (progn
              (ebib-db-set-field-value "=type=" new-type (ebib-cur-entry-key) ebib-cur-db 'overwrite)
              (ebib-fill-entry-buffer)
              (setq ebib-cur-entry-fields (ebib-get-all-fields new-type))
              (ebib-set-modified t))))
    (select-window (get-buffer-window ebib-entry-buffer) nil)))

(defun ebib-edit-crossref ()
  "Edit the crossref field."
  (unwind-protect
      (progn
        (if (eq ebib-layout 'full)
            (other-window 1)
          (select-window ebib-pre-ebib-window) nil)
        (ebib-ifstring (key (completing-read "Key to insert in `crossref': " ebib-cur-keys-list nil t))
            (progn
              (ebib-db-set-field-value "crossref" (ebib-db-brace key) (ebib-cur-entry-key) ebib-cur-db 'overwrite)
              (ebib-set-modified t))))
    (select-window (get-buffer-window ebib-entry-buffer) nil)
    ;; we now redisplay the entire entry buffer, so that the crossref'ed
    ;; fields show up. this also puts the cursor back on the type field.
    (ebib-fill-entry-buffer)
    (setq ebib-current-field "crossref")
    (re-search-forward "^crossref")
    (ebib-set-fields-highlight)))

(defun ebib-sort-keywords (keywords)
  "Sort the KEYWORDS string, remove duplicates, and return it as a string."
  (mapconcat 'identity
             (sort (delete-dups (split-string keywords ebib-keywords-separator t))
                   'string<)
             ebib-keywords-separator))

(defun ebib-edit-keywords ()
  "Edit the keywords field."
  (unwind-protect
      (progn
        (if (eq ebib-layout 'full)
            (other-window 1)
          (select-window ebib-pre-ebib-window) nil)
        ;; Now we ask the user for keywords. Note that we shadow the
        ;; binding of `minibuffer-local-completion-map' so that we can
        ;; unbind <SPC>, since keywords may contain spaces. Note also that
        ;; in Emacs 24, we can use `make-composed-keymap' for this purpose,
        ;; but in Emacs 23.1, this function is not available.
        (let ((minibuffer-local-completion-map `(keymap (keymap (32)) ,@minibuffer-local-completion-map))
              (collection (ebib-keywords-for-database ebib-cur-db)))
          (loop for keyword = (completing-read "Add a new keyword (ENTER to finish): " collection)
                until (string= keyword "")
                do (let* ((conts (ebib-db-get-field-value "keywords" (ebib-cur-entry-key) ebib-cur-db 'noerror 'unbraced))
                          (new-conts (if conts
                                         (concat conts ebib-keywords-separator keyword)
                                       keyword)))
                     (ebib-db-set-field-value "keywords"
                                              (if ebib-keywords-field-keep-sorted
                                                  (ebib-sort-keywords new-conts)
                                                new-conts)
                                              (ebib-cur-entry-key)
                                              ebib-cur-db
                                              'overwrite)
                     (ebib-set-modified t)
                     (ebib-redisplay-current-field)
                     (unless (member keyword collection)
                       (ebib-keywords-add-keyword keyword ebib-cur-db))))))
    (select-window (get-buffer-window ebib-entry-buffer) nil)))

(defun ebib-edit-field (pfx)
  "Edit a field of a BibTeX entry.
With a prefix argument `C-u', the `keyword' field can be edited
directly. For other fields, the prefix argument has no meaning."
  ;; TODO mention in the manual that the prefix must be `C-u'.
  (interactive "p")
  (cond
   ((string= ebib-current-field "=type=") (ebib-edit-entry-type))
   ((string= ebib-current-field "crossref") (ebib-edit-crossref))
   ((and (string= ebib-current-field "keywords")
         (not (= 4 pfx)))
    (ebib-edit-keywords))
   ((string= ebib-current-field "annote") (ebib-edit-multiline-field))
   (t
    (let ((init-contents (ebib-db-get-field-value ebib-current-field (ebib-cur-entry-key) ebib-cur-db 'noerror))
          (unbraced nil))
      (if (ebib-multiline-p init-contents)
          (ebib-edit-multiline-field)
        (when init-contents
          (if (ebib-db-unbraced-p init-contents)
              (setq unbraced t)
            (setq init-contents (ebib-db-unbrace init-contents))))
        (ebib-ifstring (new-contents (read-string (format "%s: " ebib-current-field)
                                           (if init-contents
                                               (cons init-contents 0)
                                             nil)
                                           ebib-minibuf-hist))
            (ebib-db-set-field-value ebib-current-field new-contents (ebib-cur-entry-key) ebib-cur-db 'overwrite unbraced)
          (ebib-db-set-field-value ebib-current-field nil (ebib-cur-entry-key) ebib-cur-db 'overwrite)
        (ebib-redisplay-current-field)
        ;; we move to the next field, but only if ebib-edit-field was
        ;; called interactively, otherwise we get a strange bug in
        ;; ebib-toggle-braced...
        (when pfx ; if called interactively
          (ebib-next-field))
        (ebib-set-modified t))))))

(defun ebib-browse-url-in-field (num)
  "Browse a URL in the current field.
The field may contain a whitespace-separated set of URLs. The
prefix argument indicates which URL is to be sent to the
browser."
  (interactive "p")
  (let ((urls (ebib-db-get-field-value ebib-current-field
                                       (ebib-cur-entry-key)
                                       ebib-cur-db
                                       'noerror 'unbraced)))
    (if urls
        (ebib-call-browser (ebib-select-url num urls))
      (error "Field `%s' is empty" ebib-current-field))))

(defun ebib-view-file-in-field (num)
  "View a file in the current field.
The field may contain a whitespace-separated set of
filenames. The prefix argument indicates which file is to be
viewed."
  (interactive "p")
  (let ((files (ebib-db-get-field-value ebib-current-field
                                        (ebib-cur-entry-key)
                                        ebib-cur-db
                                        'noerror 'unbraced)))
    (if files
        (ebib-call-file-viewer files num)
      (error "Field `%s' is empty" ebib-current-field))))

(defun ebib-copy-field-contents ()
  "Copy the contents of the current field to the kill ring."
  (interactive)
  (unless (string= ebib-current-field "=type=")
    (let ((contents (ebib-db-get-field-value ebib-current-field (ebib-cur-entry-key) ebib-cur-db 'noerror)))
      (when (stringp contents)
        (kill-new contents)
        (message "Field contents copied.")))))

(defun ebib-cut-field-contents ()
  "Kill the contents of the current field. The killed text is put in the kill ring."
  (interactive)
  (unless (string= ebib-current-field "=type=")
    (let ((contents (ebib-db-get-field-value ebib-current-field (ebib-cur-entry-key) ebib-cur-db 'noerror)))
      (when (stringp contents)
        (ebib-db-set-field-value ebib-current-field nil (ebib-cur-entry-key) ebib-cur-db 'overwrite)
        (kill-new contents)
        (ebib-redisplay-current-field)
        (ebib-set-modified t)
        (message "Field contents killed.")))))

(defun ebib-yank-field-contents (arg)
  "Yank the last killed text into the current field.
If the current field already has a contents, nothing is inserted,
unless the previous command was also `ebib-yank-field-contents',
then the field contents is replaced with the previous yank. That
is, multiple uses of this command function like the combination
of C-y/M-y. Prefix arguments also work the same as with C-y/M-y."
  (interactive "P")
  (if (or (string= ebib-current-field "=type=") ; we cannot yank into the =type= or crossref fields
          (string= ebib-current-field "crossref")
          (unless (eq last-command 'ebib-yank-field-contents)
            (ebib-db-get-field-value ebib-current-field (ebib-cur-entry-key) ebib-cur-db))) ; nor into a field already filled
      (progn
        (setq this-command t)
        (beep))
    (let ((new-contents (current-kill (cond
                                       ((listp arg) (if (eq last-command 'ebib-yank-field-contents)
                                                        1
                                                      0))
                                       ((eq arg '-) -2)
                                       (t (1- arg))))))
      (when new-contents
        (ebib-db-set-field-value ebib-current-field new-contents (ebib-cur-entry-key) ebib-cur-db 'overwrite)
        (ebib-redisplay-current-field)
        (ebib-set-modified t)))))

(defun ebib-delete-field-contents ()
  "Delete the contents of the current field.
The deleted text is not put in the kill ring."
  (interactive)
  (if (string= ebib-current-field "=type=")
      (beep)
    (when (y-or-n-p "Delete field contents? ")
      (ebib-db-set-field-value ebib-current-field nil (ebib-cur-entry-key) ebib-cur-db 'overwrite)
      (ebib-redisplay-current-field)
      (ebib-set-modified t)
      (message "Field contents deleted."))))

(defun ebib-toggle-braced ()
  "Toggle the braces around the current field contents."
  (interactive)
  (unless (or (string= ebib-current-field "=type=")
              (string= ebib-current-field "crossref")
              (string= ebib-current-field "keywords"))
    (let ((contents (ebib-db-get-field-value ebib-current-field (ebib-cur-entry-key) ebib-cur-db 'noerror)))
      (when (not contents)              ; if there is no value,
        (ebib-edit-field nil) ; the user can enter one, which we must then unbrace
        (setq contents (ebib-db-get-field-value ebib-current-field (ebib-cur-entry-key) ebib-cur-db 'noerror)))
      (ebib-db-set-field-value ebib-current-field contents (ebib-cur-entry-key) ebib-cur-db 'overwrite (not (ebib-db-unbraced-p contents)))
      (ebib-redisplay-current-field)
      (ebib-set-modified t))))

(defun ebib-edit-multiline-field ()
  "Edit the current field in multiline-mode."
  (interactive)
  (unless (or (string= ebib-current-field "=type=")
              (string= ebib-current-field "crossref"))
    (let ((text (ebib-db-get-field-value ebib-current-field (ebib-cur-entry-key) ebib-cur-db 'noerror)))
      (if (ebib-db-unbraced-p text)
          (setq ebib-multiline-unbraced t)
        (setq text (ebib-db-unbrace text))
        (setq ebib-multiline-unbraced nil))
      (select-window (ebib-temp-window) nil)
      (ebib-multiline-edit 'fields text))))

(defun ebib-insert-abbreviation ()
  "Insert an abbreviation as the current field value."
  (interactive)
  (if (ebib-db-get-field-value ebib-current-field (ebib-cur-entry-key) ebib-cur-db 'noerror)
      (beep)
    ;; we're using completing-read to read the @string abbrev, so we switch
    ;; to index window, to make sure the list of possible completions
    ;; appears in the lower window.
    (when ebib-cur-strings-list
      (unwind-protect
          (progn
            (other-window 1)
            (let ((string (completing-read "Abbreviation to insert: " ebib-cur-strings-list nil t)))
              (when string
                (ebib-db-set-field-value ebib-current-field string (ebib-cur-entry-key) ebib-cur-db 'overwrite 'nobrace)
                (ebib-set-modified t))))
        (other-window 1)
        ;; we can't do this earlier, because we would be writing to the index buffer...
        (ebib-redisplay-current-field)
        (ebib-next-field)))))

(defun ebib-entry-help ()
  "Show the info node for Ebib's entry buffer."
  (interactive)
  (setq ebib-info-flag t)
  (ebib-lower)
  (info "(ebib) The Entry Buffer"))

;;;;;;;;;;;;;;;;;;
;; strings-mode ;;
;;;;;;;;;;;;;;;;;;

(defvar ebib-strings-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map)
    (define-key map [up] 'ebib-prev-string)
    (define-key map [down] 'ebib-next-string)
    (define-key map [prior] 'ebib-strings-page-up)
    (define-key map [next] 'ebib-strings-page-down)
    (define-key map [home] 'ebib-goto-first-string)
    (define-key map [end] 'ebib-goto-last-string)
    (define-key map " " 'ebib-strings-page-down)
    (define-key map "a" 'ebib-add-string)
    (define-key map "b" 'ebib-strings-page-up)
    (define-key map "c" 'ebib-copy-string-contents)
    (define-key map "d" 'ebib-delete-string)
    (define-key map "e" 'ebib-edit-string)
    (define-key map "g" 'ebib-goto-first-string)
    (define-key map "G" 'ebib-goto-last-string)
    (define-key map "h" 'ebib-strings-help)
    (define-key map "j" 'ebib-next-string)
    (define-key map "k" 'ebib-prev-string)
    (define-key map "l" 'ebib-edit-multiline-string)
    (define-key map [(control n)] 'ebib-next-string)
    (define-key map [(meta n)] 'ebib-strings-page-down)
    (define-key map [(control p)] 'ebib-prev-string)
    (define-key map [(meta p)] 'ebib-strings-page-up)
    (define-key map "q" 'ebib-quit-strings-buffer)
    (define-key map "x" 'ebib-export-string)
    (define-key map "X" 'ebib-export-all-strings)
    (define-key map "\C-xb" 'disabled)
    (define-key map "\C-xk" 'disabled)
    map)
  "Keymap for the ebib strings buffer.")

(define-derived-mode ebib-strings-mode
  fundamental-mode "Ebib-strings"
  "Major mode for the Ebib strings buffer."
  (setq buffer-read-only t)
  (setq truncate-lines t))

(defun ebib-quit-strings-buffer ()
  "Quit editing the @STRING definitions."
  (interactive)
  (set-window-dedicated-p (selected-window) nil)
  (switch-to-buffer ebib-entry-buffer)
  (unless (eq ebib-layout 'full)
    (set-window-dedicated-p (selected-window) t))
  (select-window (get-buffer-window ebib-index-buffer) nil))

(defun ebib-prev-string ()
  "Move to the previous string."
  (interactive)
  (if (equal ebib-current-string (car ebib-cur-strings-list))  ; if we're on the first string
      (beep)
    ;; go to the beginnig of the highlight and move upward one line.
    (goto-char (ebib-highlight-start ebib-strings-highlight))
    (forward-line -1)
    (setq ebib-current-string (ebib-prev-elem ebib-current-string ebib-cur-strings-list))
    (ebib-set-strings-highlight)))

(defun ebib-next-string (&optional interactive)
  "Move to the next string."
  (interactive "p")
  (if (equal ebib-current-string (ebib-last1 ebib-cur-strings-list))
      (when interactive
        (beep))
    (goto-char (ebib-highlight-start ebib-strings-highlight))
    (forward-line 1)
    (setq ebib-current-string (ebib-next-elem ebib-current-string ebib-cur-strings-list))
    (ebib-set-strings-highlight)))

(defun ebib-goto-first-string ()
  "Move to the first string."
  (interactive)
  (setq ebib-current-string (car ebib-cur-strings-list))
  (goto-char (point-min))
  (ebib-set-strings-highlight))

(defun ebib-goto-last-string ()
  "Move to the last string."
  (interactive)
  (setq ebib-current-string (ebib-last1 ebib-cur-strings-list))
  (goto-char (point-max))
  (forward-line -1)
  (ebib-set-strings-highlight))

(defun ebib-strings-page-up ()
  "Move 10 strings up."
  (interactive)
  (let ((number-of-strings (length ebib-cur-strings-list))
        (remaining-number-of-strings (length (member ebib-current-string ebib-cur-strings-list))))
    (if (<= (- number-of-strings remaining-number-of-strings) 10)
        (ebib-goto-first-string)
      (setq ebib-current-string (nth
                                 (- number-of-strings remaining-number-of-strings 10)
                                 ebib-cur-strings-list))
      (goto-char (ebib-highlight-start ebib-strings-highlight))
      (forward-line -10)
      (ebib-set-strings-highlight)))
  (message ebib-current-string))

(defun ebib-strings-page-down ()
  "Move 10 strings down."
  (interactive)
  (let ((number-of-strings (length ebib-cur-strings-list))
        (remaining-number-of-strings (length (member ebib-current-string ebib-cur-strings-list))))
    (if (<= remaining-number-of-strings 10)
        (ebib-goto-last-string)
      (setq ebib-current-string (nth
                                 (- number-of-strings remaining-number-of-strings -10)
                                 ebib-cur-strings-list))
      (goto-char (ebib-highlight-start ebib-strings-highlight))
      (forward-line 10)
      (ebib-set-strings-highlight)))
  (message ebib-current-string))

(defun ebib-fill-strings-buffer ()
  "Fill the strings buffer with the @STRING definitions."
  (with-current-buffer ebib-strings-buffer
    (with-ebib-buffer-writable
      (erase-buffer)
      (dolist (elem ebib-cur-strings-list)
        (let ((str (ebib-db-get-string elem ebib-cur-db nil 'unbrace)))
          (insert (format "%-18s %s\n" elem
                          (if (ebib-multiline-p str)
                              (concat "+" (ebib-first-line str))
                            (concat " " str)))))))
    (goto-char (point-min))
    (setq ebib-current-string (car ebib-cur-strings-list))
    (ebib-set-strings-highlight)
    (set-buffer-modified-p nil)))

(defun ebib-edit-string ()
  "Edit the value of an @STRING definition
When the user enters an empty string, the value is not changed."
  (interactive)
  (let ((init-contents (ebib-db-get-string ebib-current-string ebib-cur-db 'noerror 'unbraced)))
    (if (ebib-multiline-p init-contents)
        (ebib-edit-multiline-string)
      (ebib-ifstring (new-contents (read-string (format "%s: " ebib-current-string)
                                         (if init-contents
                                             (cons init-contents 0)
                                           nil)
                                         ebib-minibuf-hist))
          (progn
            (ebib-store-string ebib-current-string new-content)
            (ebib-redisplay-current-string)
            (ebib-next-string))
        (error "@STRING definition cannot be empty")))))

(defun ebib-copy-string-contents ()
  "Copy the contents of the current string to the kill ring."
  (interactive)
  (kill-new (ebib-db-get-string ebib-current-string ebib-cur-db 'noerror 'unbraced))
  (message "String value copied."))

(defun ebib-delete-string ()
  "Delete the current @STRING definition from the database."
  (interactive)
  (when (y-or-n-p (format "Delete @STRING definition %s? " ebib-current-string))
    (ebib-db-set-string ebib-current-string nil ebib-cur-db 'overwrite)
    (with-ebib-buffer-writable
      (let ((beg (progn
                   (goto-char (ebib-highlight-start ebib-strings-highlight))
                   (point))))
        (forward-line 1)
        (delete-region beg (point))))
    (let ((new-cur-string (ebib-next-elem ebib-current-string ebib-cur-strings-list)))
      (setq ebib-cur-strings-list (delete ebib-current-string ebib-cur-strings-list))
      (when (null new-cur-string)       ; deleted the last string
        (setq new-cur-string (ebib-last1 ebib-cur-strings-list))
        (forward-line -1))
      (setq ebib-current-string new-cur-string))
    (ebib-set-strings-highlight)
    (ebib-set-modified t)
    (message "@STRING definition deleted.")))

(defun ebib-add-string ()
  "Create a new @STRING definition."
  (interactive)
  (ebib-ifstring (new-abbr (read-string "New @STRING abbreviation: "))
      (progn
        (if (member new-abbr ebib-cur-strings-list)
            (error (format "%s already exists" new-abbr)))
        (ebib-ifstring (new-string (read-string (format "Value for %s: " new-abbr)))
            (progn
              (ebib-store-string new-abbr new-string t)
              (with-ebib-buffer-writable
                (ebib-insert-sorted new-abbr new-string))
              (ebib-set-strings-highlight)
              (setq ebib-current-string new-abbr)
              (ebib-set-modified t))))))

;; TODO do we *really* want to be able to have multiline strings?
(defun ebib-edit-multiline-string ()
  "Edit the current string in multiline-mode."
  (interactive)
  (select-window (ebib-temp-window) nil)
  (ebib-multiline-edit 'string (ebib-db-get-string ebib-current-string ebib-cur-db 'noerror 'unbraced)))

(defun ebib-strings-help ()
  "Show the info node on Ebib's strings buffer."
  (interactive)
  (setq ebib-info-flag t)
  (ebib-lower)
  (info "(ebib) The Strings Buffer"))

;;;;;;;;;;;;;;;;;;;;
;; multiline edit ;;
;;;;;;;;;;;;;;;;;;;;

(define-minor-mode ebib-multiline-mode
  "Minor mode for Ebib's multiline edit buffer."
  :init-value nil :lighter nil :global nil
  :keymap '(("\C-c|q" . ebib-quit-multiline-edit)
            ("\C-c|c" . ebib-cancel-multiline-edit)
            ("\C-c|s" . ebib-save-from-multiline-edit)
            ("\C-c|h" . ebib-multiline-help)))

(easy-menu-define ebib-multiline-menu ebib-multiline-mode-map "Ebib multiline menu"
  '("Ebib"
    ["Store Text and Exit" ebib-quit-multiline-edit t]
    ["Cancel Edit" ebib-cancel-multiline-edit t]
    ["Save Text" ebib-save-from-multiline-edit t]
    ["Help" ebib-multiline-help t]))

(easy-menu-add ebib-multiline-menu ebib-multiline-mode-map)

(defun ebib-multiline-edit (type &optional starttext)
  "Switch to Ebib's multiline edit buffer.
STARTTEXT is a string that contains the initial text of the buffer."
  ;; note: the buffer is put in the currently active window!
  (setq ebib-pre-multiline-buffer (current-buffer))
  (switch-to-buffer ebib-multiline-buffer)
  (set-buffer-modified-p nil)
  (erase-buffer)
  (setq ebib-editing type)
  (when starttext
    (insert starttext)
    (goto-char (point-min))
    (set-buffer-modified-p nil)))

(defun ebib-quit-multiline-edit ()
  "Quit the multiline edit buffer, saving the text."
  (interactive)
  (ebib-store-multiline-text)
  (ebib-leave-multiline-edit-buffer)
  (cond
   ((eq ebib-editing 'fields)
    (ebib-next-field))
   ((eq ebib-editing 'strings)
    (ebib-next-string)))
  (message "Text stored."))

(defun ebib-cancel-multiline-edit ()
  "Quit the multiline edit buffer and discards the changes."
  (interactive)
  (catch 'no-cancel
    (when (buffer-modified-p)
      (unless (y-or-n-p "Text has been modified. Abandon changes? ")
        (throw 'no-cancel nil)))
    (ebib-leave-multiline-edit-buffer)))

(defun ebib-leave-multiline-edit-buffer ()
  "Leave the multiline edit buffer.
Restore the previous buffer in the window that the multiline
edit buffer was shown in."
  (switch-to-buffer ebib-pre-multiline-buffer)
  (cond
   ((eq ebib-editing 'preamble)
    (select-window (get-buffer-window ebib-index-buffer) nil))
   ((eq ebib-editing 'fields)
    ;; in full-frame layout, select-window isn't necessary, but it doesn't hurt either.
    (select-window (get-buffer-window ebib-entry-buffer) nil)
    (ebib-redisplay-current-field))
   ((eq ebib-editing 'strings)
    ;; in full-frame layout, select-window isn't necessary, but it doesn't hurt either.
    (select-window (get-buffer-window ebib-strings-buffer) nil)
    (ebib-redisplay-current-string))))

(defun ebib-save-from-multiline-edit ()
  "Save the database from within the multiline edit buffer.
The text being edited is stored before saving the database."
  (interactive)
  (ebib-store-multiline-text)
  (ebib-save-database ebib-cur-db)
  (set-buffer-modified-p nil))

(defun ebib-store-multiline-text ()
  "Store the text being edited in the multiline edit buffer."
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (cond
     ((eq ebib-editing 'preamble)
      (ebib-db-set-preamble (if (equal text "")
                                nil
                              text)
                            ebib-cur-db
                            'overwrite))
     ((eq ebib-editing 'fields)
      (ebib-db-set-field-value ebib-current-field
                               (if (equal text "")
                                   nil
                                 text)
                               (ebib-cur-entry-key)
                               ebib-cur-db
                               'overwrite
                               ebib-multiline-unbraced))
     ((eq ebib-editing 'strings)
      (if (equal text "")
          ;; with ERROR, we avoid execution of EBIB-SET-MODIFIED and
          ;; MESSAGE, but we also do not switch back to the strings
          ;; buffer. this may not be so bad, actually, because the user
          ;; may want to change his edit.
          (error "@STRING definition cannot be empty ")
        (ebib-db-set-string ebib-current-string (ebib-db-unbrace text) ebib-cur-db 'overwrite)))))
  (ebib-set-modified t))

(defun ebib-multiline-help ()
  "Show the info node on Ebib's multiline edit buffer."
  (interactive)
  (setq ebib-info-flag t)
  (ebib-lower)
  (info "(ebib) The Multiline Edit Buffer"))

;;;;;;;;;;;;;;;;;;;
;; ebib-log-mode ;;
;;;;;;;;;;;;;;;;;;;

(defvar ebib-log-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map)
    (define-key map " " 'scroll-up)
    (define-key map "b" 'scroll-down)
    (define-key map "q" 'ebib-quit-log-buffer)
    map)
  "Keymap for the ebib log buffer.")

(define-derived-mode ebib-log-mode
  fundamental-mode "Ebib-log"
  "Major mode for the Ebib log buffer."
  (local-set-key "\C-xb" 'ebib-quit-log-buffer)
  (local-set-key "\C-xk" 'ebib-quit-log-buffer))

(defun ebib-quit-log-buffer ()
  "Exit the log buffer."
  (interactive)
  (set-window-dedicated-p (selected-window) nil)
  (switch-to-buffer ebib-entry-buffer)
  (unless (eq ebib-layout 'full)
    (set-window-dedicated-p (selected-window) t))
  (select-window (get-buffer-window ebib-index-buffer) nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; functions for non-Ebib buffers ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ebib-import ()
  "Search for BibTeX entries in the current buffer.
The entries are added to the current database (i.e. the database
that was active when Ebib was lowered. Works on the whole buffer,
or on the region if it is active."
  (interactive)
  (if (not ebib-cur-db)
      (error "No database loaded. Use `o' to open a database")
    (save-excursion
      (save-restriction
        (if (region-active-p)
            (narrow-to-region (region-beginning)
                              (region-end)))
        (let ((result (ebib-store-bibtex-entries nil t ebib-uniquify-keys)))
          (setq ebib-cur-keys-list (ebib-db-list-keys ebib-cur-db))
          (ebib-db-set-current-entry-key (car ebib-cur-keys-list) ebib-cur-db)
          (ebib-fill-entry-buffer)
          (ebib-fill-index-buffer)
          (ebib-set-modified t)
          (message (format "%d entries, %d @STRINGs and %s @PREAMBLE found in buffer."
                           (car result)
                           (cadr result)
                           (if (cl-caddr result)
                               "a"
                             "no"))))))))

(defun ebib-get-db-from-filename (filename)
  "Return the database struct associated with FILENAME."
  (when (file-name-absolute-p filename)
    (setq filename (expand-file-name filename))) ; expand ~, . and ..
  (catch 'found
    (mapc #'(lambda (db)
              (if (string= filename
                           ;; if filename is absolute, we want to compare
                           ;; to the absolute filename of the database,
                           ;; otherwise we should use only the
                           ;; non-directory component.
                           (if (file-name-absolute-p filename)
                               (ebib-db-get-filename db)
                             (file-name-nondirectory (ebib-db-get-filename db))))
                  (throw 'found db)))
          ebib-databases)
    nil))

(defun ebib-get-local-databases ()
  "Return a list of .bib files associated with the file in the current LaTeX buffer.
Each element in the list is a string holding the name of the .bib
file. This function simply searches the current LaTeX file or its
master file for a \\bibliography command and returns the file(s)
given in its argument. If no \\bibliography command is found,
returns the symbol 'none."
  (let ((texfile-buffer (current-buffer))
        texfile)
    ;; if AucTeX's TeX-master is used and set to a string, we must
    ;; search that file for a \bibliography command, as it's more
    ;; likely to be in there than in the file we're in.
    (and (boundp 'TeX-master)
         (stringp TeX-master)
         (setq texfile (ebib-ensure-extension TeX-master "tex")))
    (with-temp-buffer
      (if (and texfile (file-readable-p texfile))
          (insert-file-contents texfile)
        (insert-buffer-substring texfile-buffer))
      (save-excursion
        (goto-char (point-min))
        (if (re-search-forward "\\\\\\(no\\)?bibliography{\\(.*?\\)}" nil t)
            (mapcar #'(lambda (file)
                        (ebib-ensure-extension file "bib"))
                    (split-string (buffer-substring-no-properties (match-beginning 2) (match-end 2)) ",[ ]*"))
          'none)))))

(defun ebib-create-collection-from-db ()
  "Create a collection of BibTeX keys.
The source of the collection is either the current database or, if the
current buffer is a LaTeX file containing a \\bibliography
command, the BibTeX files in that command (if they are open in
Ebib)."
  (or ebib-local-bibtex-filenames
      (setq ebib-local-bibtex-filenames (ebib-get-local-databases)))
  (let (collection)
    (if (eq ebib-local-bibtex-filenames 'none)
        (if (null (ebib-cur-entry-key))
            (error "No entries found in current database")
          (setq collection ebib-cur-keys-list))
      (mapc #'(lambda (file)
                (let ((db (ebib-get-db-from-filename file)))
                  (cond
                   ((null db)
                    (message "Database %s not loaded" file))
                   ((null (ebib-cur-entry-key))
                    (message "No entries in database %s" file))
                   (t (setq collection (append (ebib-db-list-keys db) collection))))))
            ebib-local-bibtex-filenames))
    collection))

(defun ebib-insert-bibtex-key ()
  "Insert a BibTeX key at POINT.
Prompt the user for a BibTeX key; possible choices are the
database(s) associated with the current LaTeX file, or the
current database if there is no \\bibliography command. Tab
completion works."
  (interactive)
  (ebib-execute-when
    ((database)
     (let ((collection (ebib-create-collection-from-db)))
       (when collection
         (let* ((key (completing-read "Key to insert: " collection nil t nil ebib-minibuf-hist))
                (format-list (or (cadr (assoc (buffer-local-value 'major-mode (current-buffer)) ebib-citation-commands))
                                 (cadr (assoc 'any ebib-citation-commands))))
                (citation-command
                 (ebib-ifstring (format-string (cadr (assoc
                                                      (completing-read "Command to use: " format-list nil nil nil ebib-minibuf-hist)
                                                      format-list)))
                                (cl-multiple-value-bind (before repeater separator after) (ebib-split-citation-string format-string)
                                  (concat (ebib-create-citation-command before)
                                          (ebib-create-citation-command repeater key)
                                          (ebib-create-citation-command after)))
                                key))) ; if the user didn't provide a command, we insert just the entry key
           (when citation-command
             (insert (format "%s" citation-command)))))))
    ((default)
     (error "No database loaded"))))

(defun ebib-entry-summary ()
  "Show the fields of the key at POINT.
The key is searched in the database associated with the LaTeX
file, or in the current database if no \\bibliography command can
be found."
  (interactive)
  (ebib-execute-when
    ((database)
     (or ebib-local-bibtex-filenames
         (setq ebib-local-bibtex-filenames (ebib-get-local-databases)))
     (let ((key (ebib-read-string-at-point "\"#%'(),={} \n\t\f")))
       (if (eq ebib-local-bibtex-filenames 'none)
           (if (not (member key ebib-cur-keys-list))
               (error "Entry `%s' is not in the current database" key))
         (let ((database (catch 'found
                           (mapc #'(lambda (file)
                                     (let ((db (ebib-get-db-from-filename file)))
                                       (if (null db)
                                           (message "Database %s not loaded" file)
                                         (if (member key ebib-cur-keys-list)
                                             (throw 'found db)))))
                                 ebib-local-bibtex-filenames)
                           nil))) ; we must return nil if the key wasn't found anywhere
           (if (null database)
               (error "Entry `%s' not found" key)
             (ebib-set-database database)))
         (ebib key t))))
    ((default)
     (error "No database(s) loaded"))))

(defun ebib-read-string-at-point (chars)
  "Read a string at POINT delimited by CHARS and returns it.
CHARS is a string of characters that should not occur in the string."
  (save-excursion
    (skip-chars-backward (concat "^" chars))
    (let ((beg (point)))
      (ebib-looking-at-goto-end (concat "[^" chars "]*"))
      (buffer-substring-no-properties beg (point)))))

;; TODO I don't think this has been documented in the database already.
;; TODO check if it works for biblatex as well.
(defun ebib-create-bib-from-bbl ()
  "Create a .bib file for the current LaTeX document.
The LaTeX document must have a .bbl file associated with it. All
bibitems are extracted from this file and a new .bib file is
created containing only these entries."
  (interactive)
  (ebib-execute-when
    ((database)
     (or ebib-local-bibtex-filenames
         (setq ebib-local-bibtex-filenames (ebib-get-local-databases)))
     (let* ((filename-sans-extension (file-name-sans-extension (buffer-file-name)))
            (bbl-file (concat filename-sans-extension ".bbl"))
            (bib-file (concat filename-sans-extension ".bib")))
       (unless (file-exists-p bbl-file)
         (error "No .bbl file exists. Run BibTeX first"))
       (when (or (not (file-exists-p bib-file))
                 (y-or-n-p (format "%s already exists. Overwrite? " (file-name-nondirectory bib-file))))
         (when (file-exists-p bib-file)
           (delete-file bib-file))
         (let ((databases
                (delq nil (mapcar #'(lambda (file)
                                      (ebib-get-db-from-filename file))
                                  ebib-local-bibtex-filenames))))
           (with-temp-buffer
             (insert-file-contents bbl-file)
             ;; TODO this won't work, as `databases' is a list, while
             ;; `ebib-export-entries' accepts only a single database.
             (ebib-export-entries (ebib-read-entries-from-bbl) databases bib-file))))))
    ((default)
     (beep))))

(defun ebib-read-entries-from-bbl ()
  (interactive)
  (goto-char (point-min))
  (let (entries)
    (while (re-search-forward "\\\\bibitem\\[.*?\\]{\\(.*?\\)}" nil t)
      (add-to-list 'entries (match-string 1) t))
    entries))

(provide 'ebib)

;;; ebib ends here
