(:eval-when (:compile-toplevel :load-toplevel)
  (ql:quickload :chirp))

(defpackage :coleslaw-twitter
  (:use :cl)
  (:import-from :coleslaw #:*config*
                          #:deploy
                          #:get-updated-files
                          #:find-content-by-path
                          #:title-of
                          #:author-of
                          #:page-url
                          #:plugin-conf-error)
  (:export #:enable))

(in-package :coleslaw-twitter)

(defvar *tweet-format* '(:title "by" :author)
  "Controls what the tweet annoucing the post looks like.")

(defvar *tweet-format-fn* nil "Function that expects an instance of
coleslaw:post and returns the tweet content.")

(defvar *tweet-format-dsl-mapping*
  '((:title . title-of)
    (:author . author-of)))

(define-condition malformed-tweet-format (error)
  ((item :initarg :item :reader item))
  (:report
   (lambda (condition stream)
     (format stream "Malformed tweet format. Can't proccess: ~A"
             (item condition)))))

(defun compile-tweet-format (tweet-format)
  (multiple-value-bind
        (fmt-ctrl-str accesors) (%compile-tweet-format tweet-format nil nil)
    (let
        ((fmt-ctrl-str (format nil "~{~A~^ ~}" (reverse fmt-ctrl-str)))
         (accesors (reverse accesors)))
      (lambda (post)
        (apply #'format nil fmt-ctrl-str
               (loop
                  :for accesor :in accesors
                  :collect (funcall accesor post)))))))

(defun %compile-tweet-format (tweet-format fmt-ctrl-str accesors)
  "Transform tweet-format into a format control string and a list of values."
  (if (null tweet-format)
      (values fmt-ctrl-str accesors)
      (let ((next (car tweet-format)))
        (cond
          ((keywordp next)
           (if (assoc next *tweet-format-dsl-mapping*)
               (%compile-tweet-format
                (cdr tweet-format)
                (cons "~A" fmt-ctrl-str)
                (cons (cdr (assoc next *tweet-format-dsl-mapping*))
                      accesors))
               (error 'malformed-tweet-format :item next)))
          ((stringp next)
           (%compile-tweet-format (cdr tweet-format)
                                  (cons next fmt-ctrl-str)
                                  accesors))
          (t (error 'malformed-tweet-format :item next))))))

(setf *tweet-format-fn* (compile-tweet-format *tweet-format*))

(defun enable (&key api-key api-secret access-token access-secret tweet-format)
  (if (and api-key api-secret access-token access-secret)
      (setf chirp:*oauth-api-key* api-key
            chirp:*oauth-api-secret* api-secret
            chirp:*oauth-access-token* access-token
            chirp:*oauth-access-secret* access-secret)
      (error 'plugin-conf-error :plugin "twitter"
             :message "Credentials missing."))

  ;; fallback to chirp for credential erros
  (chirp:account/verify-credentials)
  (when tweet-format
    (setf *tweet-format* tweet-format)))


(defmethod deploy :after (staging)
  (declare (ignore staging))
  (loop :for (state file) :in (get-updated-files)
     :when (and (string= "A" state) (string= "post" (pathname-type file)))
     :do (tweet-new-post file)))

(defun tweet-new-post (file)
  "Retrieve content matching FILE from in memory DB and publish it."
  (let ((post (find-content-by-path file)))
    (chirp:statuses/update (%format-post 0 post))))

(defun %format-post (offset post)
  "Guarantee that the tweet content is 140 chars at most. The 117 comes from
the spaxe needed for a space and the url."
  (let* ((content-prefix (subseq (render-tweet post) 0 (- 117 offset)))
         (content (format nil "~A ~A/~A" content-prefix
                          (coleslaw::domain *config*)
                          (page-url post)))
         (content-length (chirp:compute-status-length content)))
    (cond
      ((>= 140 content-length) content)
      ((< 140 content-length) (%format-post (1- offset) post)))))

(defun render-tweet (post)
  "Sans the url, which is a must."
  (funcall *tweet-format-fn* post))
