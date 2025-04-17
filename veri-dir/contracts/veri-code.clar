;; Crypto Alpha Hunters Protocol - Version 2
;; Time-locked alpha releases with enhanced tracking

;; Constants
(define-constant ERR-UNAUTHORIZED-ACCESS (err u1))
(define-constant ERR-NETWORK-INACTIVE (err u2))
(define-constant ERR-ALPHA-NOT-FOUND (err u3))
(define-constant ERR-ALPHA-ALREADY-CONFIRMED (err u4))
(define-constant ERR-INCORRECT-PROOF-HASH (err u5))
(define-constant ERR-TIME-LOCK-ACTIVE (err u6))
(define-constant ERR-INSUFFICIENT-BALANCE (err u7))
(define-constant ERR-BAD-INPUT (err u8))

;; Data Variables
(define-data-var network-operator principal tx-sender)
(define-data-var network-status bool false)
(define-data-var current-season uint u0)
(define-data-var access-fee uint u1000000) ;; 1 STX
(define-data-var reward-reserves uint u0)
(define-data-var latest-block uint u0) ;; Block height tracking for time locks

;; Alpha Structure
(define-map alpha-database
    uint
    {
        content: (string-utf8 256),
        proof-hash: (buff 32),      ;; SHA256 hash of expected confirmation proof
        unlock-time: uint,          ;; Time lock expiration block height
        bounty: uint,
        confirmed: bool
    }
)

;; Hunter Performance Tracking
(define-map hunter-records
    principal
    {
        latest-alpha: uint,
        confirmed-alphas: (list 15 uint),
        last-hunt: uint,
        total-confirmed: uint
    }
)

;; Hunt History
(define-map alpha-confirmations
    {alpha-id: uint, hunter: principal}
    {
        tries: uint,
        confirmed-at: (optional uint)
    }
)

;; Authorization
(define-private (is-operator)
    (is-eq tx-sender (var-get network-operator)))

;; Block Management
(define-public (sync-block-height (new-block uint))
    (begin
        (asserts! (is-operator) ERR-UNAUTHORIZED-ACCESS)
        ;; Ensure new block is later than current
        (asserts! (>= new-block (var-get latest-block)) ERR-BAD-INPUT)
        (var-set latest-block new-block)
        (ok true)))

;; Network Management Functions
(define-public (launch-network)
    (begin
        (asserts! (is-operator) ERR-UNAUTHORIZED-ACCESS)
        (var-set network-status true)
        (var-set current-season u0)
        (var-set reward-reserves u0)
        (ok true)))

(define-public (register-alpha
    (alpha-id uint)
    (content (string-utf8 256))
    (proof-hash (buff 32))
    (unlock-time uint)
    (bounty uint))
    (begin
        (asserts! (is-operator) ERR-UNAUTHORIZED-ACCESS)
        
        ;; Validate unlock time is in future
        (asserts! (>= unlock-time (var-get latest-block)) ERR-BAD-INPUT)
        
        ;; Set the alpha data
        (map-set alpha-database alpha-id
            {
                content: content,
                proof-hash: proof-hash,
                unlock-time: unlock-time,
                bounty: bounty,
                confirmed: false
            })
            
        ;; Calculate new reserves safely
        (let ((new-reserves (+ (var-get reward-reserves) bounty)))
            ;; Update the total reserves
            (var-set reward-reserves new-reserves))
        (ok true)))

;; Hunter Onboarding
(define-public (join-hunt)
    (begin
        (asserts! (var-get network-status) ERR-NETWORK-INACTIVE)
        ;; Require access fee
        (try! (stx-transfer? (var-get access-fee) tx-sender (var-get network-operator)))
        
        (map-set hunter-records tx-sender
            {
                latest-alpha: u0,
                confirmed-alphas: (list),
                last-hunt: u0,
                total-confirmed: u0
            })
        (ok true)))

;; Alpha Confirmation Functions
(define-public (confirm-alpha
    (alpha-id uint)
    (confirmation-proof (buff 32)))
    (let (
        (alpha (unwrap! (map-get? alpha-database alpha-id) ERR-ALPHA-NOT-FOUND))
        (hunter (unwrap! (map-get? hunter-records tx-sender) ERR-ALPHA-NOT-FOUND))
        (current-block (var-get latest-block))
        )
        ;; Check alpha availability
        (asserts! (var-get network-status) ERR-NETWORK-INACTIVE)
        (asserts! (>= current-block (get unlock-time alpha)) ERR-TIME-LOCK-ACTIVE)
        (asserts! (not (get confirmed alpha)) ERR-ALPHA-ALREADY-CONFIRMED)
        
        ;; Verify confirmation proof
        (if (is-eq confirmation-proof (get proof-hash alpha))
            (begin
                ;; Update alpha status
                (map-set alpha-database alpha-id
                    (merge alpha {confirmed: true}))
                
                ;; Update hunter records
                (map-set hunter-records tx-sender
                    (merge hunter {
                        latest-alpha: (+ alpha-id u1),
                        confirmed-alphas: (unwrap! (as-max-len? 
                            (append (get confirmed-alphas hunter) alpha-id) u15)
                            ERR-ALPHA-NOT-FOUND),
                        last-hunt: current-block,
                        total-confirmed: (+ (get total-confirmed hunter) u1)
                    }))
                
                ;; Record confirmation
                (map-set alpha-confirmations
                    {alpha-id: alpha-id, hunter: tx-sender}
                    {
                        tries: u1,
                        confirmed-at: (some current-block)
                    })
                
                ;; Distribute bounty
                (try! (stx-transfer? (get bounty alpha) (var-get network-operator) tx-sender))
                
                (ok true))
            ERR-INCORRECT-PROOF-HASH)))

;; Read-only functions
(define-read-only (view-alpha-content (alpha-id uint))
    (match (map-get? alpha-database alpha-id)
        alpha (if (>= (var-get latest-block) (get unlock-time alpha))
            (ok (get content alpha))
            ERR-TIME-LOCK-ACTIVE)
        ERR-ALPHA-NOT-FOUND))

(define-read-only (get-hunter-profile (hunter principal))
    (map-get? hunter-records hunter))

(define-read-only (get-confirmation-record (alpha-id uint) (hunter principal))
    (map-get? alpha-confirmations {alpha-id: alpha-id, hunter: hunter}))

(define-read-only (get-latest-block)
    (var-get latest-block))

(define-read-only (get-network-metrics)
    {
        active: (var-get network-status),
        current-season: (var-get current-season),
        reward-reserves: (var-get reward-reserves),
        access-fee: (var-get access-fee),
        latest-block: (var-get latest-block)
    })