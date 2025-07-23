;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-SERVICE-NOT-FOUND (err u101))
(define-constant ERR-SUBSCRIPTION-NOT-FOUND (err u102))
(define-constant ERR-ALREADY-SUBSCRIBED (err u103))
(define-constant ERR-INVALID-INPUT (err u104))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u105))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u106))
(define-constant ERR-INVALID-SERVICE-ID (err u107))
(define-constant ERR-EMPTY-STRING (err u108))
(define-constant ERR-INVALID-TIER (err u109))
(define-constant ERR-SERVICE-INACTIVE (err u110))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant PLATFORM-FEE-PERCENT u3) ;; 3% platform fee
(define-constant MIN-SUBSCRIPTION-PRICE u1000000) ;; 1 STX minimum
(define-constant BLOCKS-PER-MONTH u4320) ;; Approximate blocks in 30 days

;; Service tiers
(define-constant TIER-BASIC "BASIC")
(define-constant TIER-PREMIUM "PREMIUM")
(define-constant TIER-ENTERPRISE "ENTERPRISE")

;; Service categories
(define-constant CATEGORY-SAAS "SAAS")
(define-constant CATEGORY-CONTENT "CONTENT")
(define-constant CATEGORY-MEDIA "MEDIA")
(define-constant CATEGORY-EDUCATION "EDUCATION")
(define-constant CATEGORY-GAMING "GAMING")

;; Data structures
(define-map subscription-services
    { service-id: uint }
    {
        provider: principal,
        name: (string-ascii 100),
        description: (string-ascii 500),
        category: (string-ascii 50),
        tier: (string-ascii 20),
        monthly-price: uint,
        max-subscribers: uint,
        current-subscribers: uint,
        features: (string-ascii 300),
        active: bool,
        created-block: uint,
        total-revenue: uint,
        average-rating: uint,
        total-ratings: uint
    }
)

(define-map user-subscriptions
    { service-id: uint, subscriber: principal }
    {
        subscription-start: uint,
        subscription-end: uint,
        last-payment: uint,
        total-paid: uint,
        auto-renew: bool,
        payment-failures: uint,
        subscription-status: (string-ascii 20),
        tier-level: (string-ascii 20)
    }
)

(define-map subscription-payments
    { service-id: uint, subscriber: principal, payment-id: uint }
    {
        amount: uint,
        payment-block: uint,
        period-start: uint,
        period-end: uint,
        payment-method: (string-ascii 20)
    }
)

(define-map provider-profiles
    { provider: principal }
    {
        name: (string-ascii 100),
        services-created: uint,
        total-subscribers: uint,
        total-revenue: uint,
        average-rating: uint,
        verified: bool,
        registration-block: uint
    }
)

(define-map service-analytics
    { service-id: uint, metric: (string-ascii 50) }
    { value: uint, last-updated: uint }
)

;; State variables
(define-data-var service-counter uint u0)
(define-data-var payment-counter uint u0)
(define-data-var platform-revenue uint u0)

;; Input validation functions
(define-private (is-valid-string (str (string-ascii 500)))
    (> (len str) u0)
)

(define-private (is-valid-service-id (service-id uint))
    (and (> service-id u0) (<= service-id (var-get service-counter)))
)

(define-private (is-valid-price (price uint))
    (>= price MIN-SUBSCRIPTION-PRICE)
)

(define-private (is-valid-tier (tier (string-ascii 20)))
    (or (is-eq tier TIER-BASIC)
        (or (is-eq tier TIER-PREMIUM)
            (is-eq tier TIER-ENTERPRISE)))
)

(define-private (is-valid-category (category (string-ascii 50)))
    (or (is-eq category CATEGORY-SAAS)
        (or (is-eq category CATEGORY-CONTENT)
            (or (is-eq category CATEGORY-MEDIA)
                (or (is-eq category CATEGORY-EDUCATION)
                    (is-eq category CATEGORY-GAMING)))))
)

(define-private (is-valid-max-subscribers (max-subs uint))
    (and (> max-subs u0) (<= max-subs u100000))
)

;; Create new subscription service
(define-public (create-subscription-service 
                (name (string-ascii 100))
                (description (string-ascii 500))
                (category (string-ascii 50))
                (tier (string-ascii 20))
                (monthly-price uint)
                (max-subscribers uint)
                (features (string-ascii 300)))
    (let
        (
            (new-service-id (+ (var-get service-counter) u1))
        )
        ;; Input validation
        (asserts! (is-valid-string name) ERR-EMPTY-STRING)
        (asserts! (is-valid-string description) ERR-EMPTY-STRING)
        (asserts! (is-valid-category category) ERR-INVALID-INPUT)
        (asserts! (is-valid-tier tier) ERR-INVALID-TIER)
        (asserts! (is-valid-price monthly-price) ERR-INVALID-INPUT)
        (asserts! (is-valid-max-subscribers max-subscribers) ERR-INVALID-INPUT)
        (asserts! (is-valid-string features) ERR-EMPTY-STRING)
        
        ;; Create service
        (map-set subscription-services
            { service-id: new-service-id }
            {
                provider: tx-sender,
                name: name,
                description: description,
                category: category,
                tier: tier,
                monthly-price: monthly-price,
                max-subscribers: max-subscribers,
                current-subscribers: u0,
                features: features,
                active: true,
                created-block: block-height,
                total-revenue: u0,
                average-rating: u0,
                total-ratings: u0
            }
        )
        
        ;; Update provider profile
        (update-provider-profile tx-sender true)
        
        ;; Initialize analytics
        (map-set service-analytics 
            { service-id: new-service-id, metric: "monthly-growth" }
            { value: u0, last-updated: block-height })
        
        (var-set service-counter new-service-id)
        (ok new-service-id)
    )
)

;; Subscribe to a service
(define-public (subscribe-to-service (service-id uint) (auto-renew bool))
    (let
        (
            (service-info (unwrap! (map-get? subscription-services { service-id: service-id }) ERR-SERVICE-NOT-FOUND))
            (monthly-price (get monthly-price service-info))
            (platform-fee (/ (* monthly-price PLATFORM-FEE-PERCENT) u100))
            (provider-payment (- monthly-price platform-fee))
            (subscription-end (+ block-height BLOCKS-PER-MONTH))
        )
        ;; Validation
        (asserts! (is-valid-service-id service-id) ERR-INVALID-SERVICE-ID)
        (asserts! (get active service-info) ERR-SERVICE-INACTIVE)
        (asserts! (< (get current-subscribers service-info) (get max-subscribers service-info)) ERR-INVALID-INPUT)
        (asserts! (is-none (map-get? user-subscriptions { service-id: service-id, subscriber: tx-sender })) ERR-ALREADY-SUBSCRIBED)
        
        ;; Process payment
        (try! (stx-transfer? monthly-price tx-sender (as-contract tx-sender)))
        
        ;; Create subscription
        (map-set user-subscriptions
            { service-id: service-id, subscriber: tx-sender }
            {
                subscription-start: block-height,
                subscription-end: subscription-end,
                last-payment: block-height,
                total-paid: monthly-price,
                auto-renew: auto-renew,
                payment-failures: u0,
                subscription-status: "ACTIVE",
                tier-level: (get tier service-info)
            }
        )
        
        ;; Record payment
        (let ((payment-id (+ (var-get payment-counter) u1)))
            (map-set subscription-payments
                { service-id: service-id, subscriber: tx-sender, payment-id: payment-id }
                {
                    amount: monthly-price,
                    payment-block: block-height,
                    period-start: block-height,
                    period-end: subscription-end,
                    payment-method: "STX"
                }
            )
            (var-set payment-counter payment-id)
        )
        
        ;; Update service statistics
        (map-set subscription-services
            { service-id: service-id }
            (merge service-info {
                current-subscribers: (+ (get current-subscribers service-info) u1),
                total-revenue: (+ (get total-revenue service-info) provider-payment)
            })
        )
        
        ;; Distribute payments
        (try! (as-contract (stx-transfer? provider-payment tx-sender (get provider service-info))))
        (var-set platform-revenue (+ (var-get platform-revenue) platform-fee))
        
        ;; Update analytics
        (update-service-analytics service-id "new-subscribers" u1)
        (update-provider-profile (get provider service-info) false)
        
        (ok subscription-end)
    )
)

;; Renew subscription
(define-public (renew-subscription (service-id uint))
    (let
        (
            (service-info (unwrap! (map-get? subscription-services { service-id: service-id }) ERR-SERVICE-NOT-FOUND))
            (subscription-info (unwrap! (map-get? user-subscriptions { service-id: service-id, subscriber: tx-sender }) ERR-SUBSCRIPTION-NOT-FOUND))
            (monthly-price (get monthly-price service-info))
            (platform-fee (/ (* monthly-price PLATFORM-FEE-PERCENT) u100))
            (provider-payment (- monthly-price platform-fee))
            (new-end-date (+ (get subscription-end subscription-info) BLOCKS-PER-MONTH))
        )
        ;; Validation
        (asserts! (is-valid-service-id service-id) ERR-INVALID-SERVICE-ID)
        (asserts! (get active service-info) ERR-SERVICE-INACTIVE)
        (asserts! (>= block-height (- (get subscription-end subscription-info) u144)) ERR-INVALID-INPUT) ;; Can renew 1 day before expiry
        
        ;; Process payment
        (try! (stx-transfer? monthly-price tx-sender (as-contract tx-sender)))
        
        ;; Update subscription
        (map-set user-subscriptions
            { service-id: service-id, subscriber: tx-sender }
            (merge subscription-info {
                subscription-end: new-end-date,
                last-payment: block-height,
                total-paid: (+ (get total-paid subscription-info) monthly-price),
                payment-failures: u0,
                subscription-status: "ACTIVE"
            })
        )
        
        ;; Record payment
        (let ((payment-id (+ (var-get payment-counter) u1)))
            (map-set subscription-payments
                { service-id: service-id, subscriber: tx-sender, payment-id: payment-id }
                {
                    amount: monthly-price,
                    payment-block: block-height,
                    period-start: (get subscription-end subscription-info),
                    period-end: new-end-date,
                    payment-method: "STX"
                }
            )
            (var-set payment-counter payment-id)
        )
        
        ;; Update service revenue
        (map-set subscription-services
            { service-id: service-id }
            (merge service-info {
                total-revenue: (+ (get total-revenue service-info) provider-payment)
            })
        )
        
        ;; Distribute payments
        (try! (as-contract (stx-transfer? provider-payment tx-sender (get provider service-info))))
        (var-set platform-revenue (+ (var-get platform-revenue) platform-fee))
        
        ;; Update analytics
        (update-service-analytics service-id "renewals" u1)
        
        (ok new-end-date)
    )
)

;; Cancel subscription
(define-public (cancel-subscription (service-id uint))
    (let
        (
            (service-info (unwrap! (map-get? subscription-services { service-id: service-id }) ERR-SERVICE-NOT-FOUND))
            (subscription-info (unwrap! (map-get? user-subscriptions { service-id: service-id, subscriber: tx-sender }) ERR-SUBSCRIPTION-NOT-FOUND))
        )
        ;; Validation
        (asserts! (is-valid-service-id service-id) ERR-INVALID-SERVICE-ID)
        (asserts! (is-eq (get subscription-status subscription-info) "ACTIVE") ERR-SUBSCRIPTION-EXPIRED)
        
        ;; Cancel subscription
        (map-set user-subscriptions
            { service-id: service-id, subscriber: tx-sender }
            (merge subscription-info {
                auto-renew: false,
                subscription-status: "CANCELLED"
            })
        )
        
        ;; Update service subscriber count
        (map-set subscription-services
            { service-id: service-id }
            (merge service-info {
                current-subscribers: (- (get current-subscribers service-info) u1)
            })
        )
        
        ;; Update analytics
        (update-service-analytics service-id "cancellations" u1)
        
        (ok true)
    )
)

;; Check subscription access
(define-read-only (has-active-subscription (service-id uint) (user principal))
    (match (map-get? user-subscriptions { service-id: service-id, subscriber: user })
        subscription-data 
        (and (> (get subscription-end subscription-data) block-height)
             (is-eq (get subscription-status subscription-data) "ACTIVE"))
        false)
)

;; Rate service
(define-public (rate-service (service-id uint) (rating uint))
    (let
        (
            (service-info (unwrap! (map-get? subscription-services { service-id: service-id }) ERR-SERVICE-NOT-FOUND))
            (subscription-info (unwrap! (map-get? user-subscriptions { service-id: service-id, subscriber: tx-sender }) ERR-SUBSCRIPTION-NOT-FOUND))
        )
        ;; Validation
        (asserts! (is-valid-service-id service-id) ERR-INVALID-SERVICE-ID)
        (asserts! (and (>= rating u1) (<= rating u5)) ERR-INVALID-INPUT)
        (asserts! (has-active-subscription service-id tx-sender) ERR-SUBSCRIPTION-EXPIRED)
        
        ;; Update service rating
        (let
            (
                (total-ratings (get total-ratings service-info))
                (current-rating-sum (* (get average-rating service-info) total-ratings))
                (new-total-ratings (+ total-ratings u1))
                (new-rating-sum (+ current-rating-sum rating))
                (new-average (/ new-rating-sum new-total-ratings))
            )
            (map-set subscription-services
                { service-id: service-id }
                (merge service-info {
                    average-rating: new-average,
                    total-ratings: new-total-ratings
                })
            )
        )
        
        (ok true)
    )
)

;; Update provider profile
(define-private (update-provider-profile (provider principal) (new-service bool))
    (let
        (
            (current-profile (default-to 
                            { name: "", services-created: u0, total-subscribers: u0, 
                              total-revenue: u0, average-rating: u0, verified: false, registration-block: block-height }
                            (map-get? provider-profiles { provider: provider })))
        )
        (map-set provider-profiles
            { provider: provider }
            (if new-service
                (merge current-profile {
                    services-created: (+ (get services-created current-profile) u1)
                })
                (merge current-profile {
                    total-subscribers: (+ (get total-subscribers current-profile) u1)
                })
            )
        )
    )
)

;; Update service analytics
(define-private (update-service-analytics (service-id uint) (metric (string-ascii 50)) (increment uint))
    (let
        (
            (current-metric (default-to { value: u0, last-updated: u0 }
                                       (map-get? service-analytics { service-id: service-id, metric: metric })))
        )
        (map-set service-analytics
            { service-id: service-id, metric: metric }
            {
                value: (+ (get value current-metric) increment),
                last-updated: block-height
            }
        )
    )
)

;; Admin functions
(define-public (verify-service (service-id uint))
    (let
        (
            (service-info (unwrap! (map-get? subscription-services { service-id: service-id }) ERR-SERVICE-NOT-FOUND))
        )
        (asserts! (is-valid-service-id service-id) ERR-INVALID-SERVICE-ID)
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        
        ;; Service verification handled at provider level
        (let ((provider (get provider service-info)))
            (match (map-get? provider-profiles { provider: provider })
                profile-data (map-set provider-profiles
                                    { provider: provider }
                                    (merge profile-data { verified: true }))
                false)
        )
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-service-info (service-id uint))
    (map-get? subscription-services { service-id: service-id })
)

(define-read-only (get-subscription-info (service-id uint) (subscriber principal))
    (map-get? user-subscriptions { service-id: service-id, subscriber: subscriber })
)

(define-read-only (get-provider-profile (provider principal))
    (map-get? provider-profiles { provider: provider })
)

(define-read-only (get-service-analytics (service-id uint) (metric (string-ascii 50)))
    (map-get? service-analytics { service-id: service-id, metric: metric })
)

(define-read-only (get-total-services)
    (var-get service-counter)
)

(define-read-only (get-platform-revenue)
    (var-get platform-revenue)
)

(define-read-only (get-payment-info (service-id uint) (subscriber principal) (payment-id uint))
    (map-get? subscription-payments { service-id: service-id, subscriber: subscriber, payment-id: payment-id })
)