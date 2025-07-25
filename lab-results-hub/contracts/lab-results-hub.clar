;; LabResults Hub - Laboratory Result Verification System
;; Version: 1.0.0

(define-constant ERR_NOT_AUTHORIZED (err u200))
(define-constant ERR_RESULT_NOT_FOUND (err u201))
(define-constant ERR_INVALID_VERIFIER (err u202))
(define-constant ERR_ALREADY_VERIFIED (err u203))
(define-constant ERR_VERIFICATION_EXPIRED (err u204))

(define-map lab-results
  { result-id: uint }
  {
    patient-id: principal,
    laboratory: principal,
    test-name: (string-ascii 100),
    result-data: (string-ascii 600),
    units: (string-ascii 50),
    normal-range: (string-ascii 100),
    result-timestamp: uint,
    verification-status: (string-ascii 20),
    verification-deadline: uint,
    critical-value: bool
  }
)

(define-map verification-records
  { result-id: uint, verifier-id: principal }
  {
    verification-date: uint,
    verification-method: (string-ascii 50),
    confidence-score: uint,
    digital-signature: (buff 64),
    verification-notes: (string-ascii 300),
    is-valid: bool
  }
)

(define-map authorized-verifiers
  { verifier-id: principal }
  {
    verifier-name: (string-ascii 100),
    verification-type: (string-ascii 50),
    certification-level: (string-ascii 30),
    authorized-tests: (string-ascii 200),
    registration-date: uint,
    is-active: bool
  }
)

(define-map result-challenges
  { result-id: uint, challenge-id: uint }
  {
    challenger: principal,
    challenge-reason: (string-ascii 200),
    challenge-date: uint,
    evidence-hash: (buff 32),
    status: (string-ascii 30),
    resolution-date: uint
  }
)

(define-map verification-consensus
  { result-id: uint }
  {
    total-verifications: uint,
    positive-verifications: uint,
    consensus-reached: bool,
    consensus-threshold: uint,
    final-status: (string-ascii 30)
  }
)

(define-data-var next-result-id uint u1)
(define-data-var next-challenge-id uint u1)
(define-data-var verification-threshold uint u3)

(define-constant contract-owner tx-sender)

(define-public (register-verifier
  (verifier-id principal)
  (verifier-name (string-ascii 100))
  (verification-type (string-ascii 50))
  (certification-level (string-ascii 30))
  (authorized-tests (string-ascii 200)))
  (begin
    (asserts! (is-eq tx-sender contract-owner) ERR_NOT_AUTHORIZED)
    (map-set authorized-verifiers
      { verifier-id: verifier-id }
      {
        verifier-name: verifier-name,
        verification-type: verification-type,
        certification-level: certification-level,
        authorized-tests: authorized-tests,
        registration-date: block-height,
        is-active: true
      }
    )
    (ok true)
  )
)

(define-public (submit-lab-result
  (patient-id principal)
  (test-name (string-ascii 100))
  (result-data (string-ascii 600))
  (units (string-ascii 50))
  (normal-range (string-ascii 100))
  (verification-deadline uint)
  (critical-value bool))
  (let ((result-id (var-get next-result-id)))
    (map-set lab-results
      { result-id: result-id }
      {
        patient-id: patient-id,
        laboratory: tx-sender,
        test-name: test-name,
        result-data: result-data,
        units: units,
        normal-range: normal-range,
        result-timestamp: block-height,
        verification-status: "pending",
        verification-deadline: verification-deadline,
        critical-value: critical-value
      }
    )
    (map-set verification-consensus
      { result-id: result-id }
      {
        total-verifications: u0,
        positive-verifications: u0,
        consensus-reached: false,
        consensus-threshold: (if critical-value u5 u3),
        final-status: "pending"
      }
    )
    (var-set next-result-id (+ result-id u1))
    (ok result-id)
  )
)

(define-public (verify-result
  (result-id uint)
  (verification-method (string-ascii 50))
  (confidence-score uint)
  (digital-signature (buff 64))
  (verification-notes (string-ascii 300))
  (is-valid bool))
  (let ((result-data (unwrap! (map-get? lab-results { result-id: result-id }) ERR_RESULT_NOT_FOUND))
        (verifier-data (unwrap! (map-get? authorized-verifiers { verifier-id: tx-sender }) ERR_INVALID_VERIFIER))
        (existing-verification (map-get? verification-records { result-id: result-id, verifier-id: tx-sender }))
        (consensus-data (unwrap! (map-get? verification-consensus { result-id: result-id }) ERR_RESULT_NOT_FOUND)))
    (asserts! (get is-active verifier-data) ERR_INVALID_VERIFIER)
    (asserts! (is-none existing-verification) ERR_ALREADY_VERIFIED)
    (asserts! (< block-height (get verification-deadline result-data)) ERR_VERIFICATION_EXPIRED)
    (map-set verification-records
      { result-id: result-id, verifier-id: tx-sender }
      {
        verification-date: block-height,
        verification-method: verification-method,
        confidence-score: confidence-score,
        digital-signature: digital-signature,
        verification-notes: verification-notes,
        is-valid: is-valid
      }
    )
    (let ((new-total (+ (get total-verifications consensus-data) u1))
          (new-positive (if is-valid (+ (get positive-verifications consensus-data) u1) (get positive-verifications consensus-data))))
      (map-set verification-consensus
        { result-id: result-id }
        (merge consensus-data {
          total-verifications: new-total,
          positive-verifications: new-positive,
          consensus-reached: (>= new-positive (get consensus-threshold consensus-data)),
          final-status: (if (>= new-positive (get consensus-threshold consensus-data)) "verified" "pending")
        })
      )
      (if (>= new-positive (get consensus-threshold consensus-data))
        (map-set lab-results
          { result-id: result-id }
          (merge result-data { verification-status: "verified" })
        )
        true
      )
    )
    (ok true)
  )
)

(define-public (challenge-result
  (result-id uint)
  (challenge-reason (string-ascii 200))
  (evidence-hash (buff 32)))
  (let ((result-data (unwrap! (map-get? lab-results { result-id: result-id }) ERR_RESULT_NOT_FOUND))
        (challenge-id (var-get next-challenge-id)))
    (asserts! (is-some (map-get? authorized-verifiers { verifier-id: tx-sender })) ERR_INVALID_VERIFIER)
    (map-set result-challenges
      { result-id: result-id, challenge-id: challenge-id }
      {
        challenger: tx-sender,
        challenge-reason: challenge-reason,
        challenge-date: block-height,
        evidence-hash: evidence-hash,
        status: "open",
        resolution-date: u0
      }
    )
    (map-set lab-results
      { result-id: result-id }
      (merge result-data { verification-status: "challenged" })
    )
    (var-set next-challenge-id (+ challenge-id u1))
    (ok challenge-id)
  )
)

(define-public (resolve-challenge
  (result-id uint)
  (challenge-id uint)
  (resolution (string-ascii 30)))
  (let ((challenge-data (unwrap! (map-get? result-challenges { result-id: result-id, challenge-id: challenge-id }) ERR_RESULT_NOT_FOUND))
        (result-data (unwrap! (map-get? lab-results { result-id: result-id }) ERR_RESULT_NOT_FOUND)))
    (asserts! (is-eq tx-sender contract-owner) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (get status challenge-data) "open") ERR_NOT_AUTHORIZED)
    (map-set result-challenges
      { result-id: result-id, challenge-id: challenge-id }
      (merge challenge-data {
        status: resolution,
        resolution-date: block-height
      })
    )
    (if (is-eq resolution "upheld")
      (map-set lab-results
        { result-id: result-id }
        (merge result-data { verification-status: "invalid" })
      )
      (map-set lab-results
        { result-id: result-id }
        (merge result-data { verification-status: "verified" })
      )
    )
    (ok true)
  )
)

(define-public (update-verification-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) ERR_NOT_AUTHORIZED)
    (var-set verification-threshold new-threshold)
    (ok true)
  )
)

(define-read-only (get-lab-result (result-id uint))
  (map-get? lab-results { result-id: result-id })
)

(define-read-only (get-verification-record (result-id uint) (verifier-id principal))
  (map-get? verification-records { result-id: result-id, verifier-id: verifier-id })
)

(define-read-only (get-verifier-info (verifier-id principal))
  (map-get? authorized-verifiers { verifier-id: verifier-id })
)

(define-read-only (get-result-challenge (result-id uint) (challenge-id uint))
  (map-get? result-challenges { result-id: result-id, challenge-id: challenge-id })
)

(define-read-only (get-verification-consensus (result-id uint))
  (map-get? verification-consensus { result-id: result-id })
)

(define-read-only (get-verification-threshold)
  (var-get verification-threshold)
)

(define-read-only (get-next-result-id)
  (var-get next-result-id)
)

(define-read-only (get-next-challenge-id)
  (var-get next-challenge-id)
)