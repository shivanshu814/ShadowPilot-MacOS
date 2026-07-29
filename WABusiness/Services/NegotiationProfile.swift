import Foundation

// MARK: - Market

// Where the role sits decides almost everything about a pay conversation: the
// currency, how an offer is even quoted (LPA vs base+RSU vs 14 monthly
// salaries), which levers are movable, and what a normal ask sounds like. So
// the country picker changes the ADVICE, not just the symbol in front of the
// number.
enum SalaryCountry: String, CaseIterable, Identifiable {
    case india, usa, uk, germany, netherlands, canada, uae, singapore, australia, global
    var id: String { rawValue }

    var flag: String {
        switch self {
        case .india:       return "🇮🇳"
        case .usa:         return "🇺🇸"
        case .uk:          return "🇬🇧"
        case .germany:     return "🇩🇪"
        case .netherlands: return "🇳🇱"
        case .canada:      return "🇨🇦"
        case .uae:         return "🇦🇪"
        case .singapore:   return "🇸🇬"
        case .australia:   return "🇦🇺"
        case .global:      return "🌍"
        }
    }

    // Short code for the compact chip in the bar / setup header
    var code: String {
        switch self {
        case .india:       return "IN"
        case .usa:         return "US"
        case .uk:          return "UK"
        case .germany:     return "DE"
        case .netherlands: return "NL"
        case .canada:      return "CA"
        case .uae:         return "AE"
        case .singapore:   return "SG"
        case .australia:   return "AU"
        case .global:      return "REMOTE"
        }
    }

    var name: String {
        switch self {
        case .india:       return "India"
        case .usa:         return "United States"
        case .uk:          return "United Kingdom"
        case .germany:     return "Germany"
        case .netherlands: return "Netherlands"
        case .canada:      return "Canada"
        case .uae:         return "UAE"
        case .singapore:   return "Singapore"
        case .australia:   return "Australia"
        case .global:      return "Global / remote-first"
        }
    }

    var currency: String {
        switch self {
        case .india:       return "INR ₹"
        case .usa:         return "USD $"
        case .uk:          return "GBP £"
        case .germany, .netherlands: return "EUR €"
        case .canada:      return "CAD $"
        case .uae:         return "AED"
        case .singapore:   return "SGD $"
        case .australia:   return "AUD $"
        case .global:      return "USD $ (or the payroll currency)"
        }
    }

    // Placeholder text that teaches the local convention by example — an Indian
    // user should not have to think in "base + RSU", and vice versa.
    var payHint: String {
        switch self {
        case .india:       return "e.g. 24 LPA fixed + 3 LPA variable"
        case .usa:         return "e.g. $165k base + 15% bonus + $80k RSU/4yr"
        case .uk:          return "e.g. £85k base + 10% bonus + 5% pension"
        case .germany:     return "e.g. €85k gross / 12 months + €5k bonus"
        case .netherlands: return "e.g. €80k gross + 8% holiday allowance"
        case .canada:      return "e.g. C$150k base + 10% bonus + RSUs"
        case .uae:         return "e.g. AED 45k/month all-in, tax free"
        case .singapore:   return "e.g. S$150k base + 1 month AWS"
        case .australia:   return "e.g. A$180k base + 11.5% super"
        case .global:      return "e.g. $120k base, location-agnostic band"
        }
    }

    // The market rules the model has to respect. Facts about how offers are
    // STRUCTURED here — deliberately not salary figures, which go stale and
    // would just invite the model to invent a number and present it as data.
    var norms: String {
        switch self {
        case .india:
            return """
            India. Money is spoken in lakhs per annum (LPA); 100 lakh = 1 crore. Offers are quoted as CTC, which deliberately blurs things — always split it into fixed, variable/performance pay, joining bonus, retention bonus, gratuity and the employer PF share, and steer the conversation to FIXED and to monthly in-hand. ESOPs at a private startup are worth nothing until there is a real buyback or secondary history: ask for the strike price, the latest 409A/fair value, total outstanding shares and whether any past buyback happened, and value them near zero when comparing offers. A notice-period buyout is a normal, expected ask. On a switch, a 30-50% jump on fixed is standard and more is defensible when the current pay is clearly below market or the scope steps up. Variable pay hits the bank quarterly or yearly, so a package that is heavy on variable is worth materially less than the same CTC that is heavy on fixed — say that plainly.
            """
        case .usa:
            return """
            United States. The package is base + target bonus + equity + sign-on, and every one of them is a separate negotiation. At a public company equity is RSUs, typically vesting over 4 years with a 1-year cliff — quote the annual grant value, not the headline total. At a startup it is options: strike price, number of shares, percentage of fully diluted, preferred valuation and exercise window all matter, and the number alone is meaningless. LEVEL beats number: being placed one level higher is worth far more than a 10k base bump, and it compounds at every refresh. Sign-on bonus and equity are usually the easiest things for the company to move; base is the most band-constrained. Several states require the pay range to be disclosed on request — asking for the band for the level is normal, not aggressive.
            """
        case .uk:
            return """
            United Kingdom. Salary is quoted as annual gross base. Bonus is smaller than in the US and often discretionary — treat discretionary bonus as zero when comparing. Pension employer contribution (5-10%+) is real money and is negotiable at some firms. Startup equity is usually EMI share options, which have genuinely favourable tax treatment — worth asking whether the scheme is EMI. Also on the table: private health cover, extra annual leave days, and a signing/relocation payment.
            """
        case .germany:
            return """
            Germany. Salary is quoted as annual gross, sometimes split across 13 or 14 monthly payments — always confirm which, because 14 payments changes the monthly figure a lot. Bands are more rigid than in the US, and at larger firms a works council or collective agreement (Tarifvertrag) can cap what a manager can do — in that case negotiate on the level/band, not on the number. Equity is uncommon outside startups. Vacation days above the statutory minimum, a company car or transport allowance, and relocation support are all legitimate levers. Notice periods are long, so a start date is itself a negotiable term.
            """
        case .netherlands:
            return """
            Netherlands. Salary is annual gross, plus a statutory 8% holiday allowance paid in May — confirm whether the quoted number includes it. If you are relocating, the 30% ruling is worth a large chunk of net pay: ask explicitly whether the employer will apply for it and whether they will cover the gap if it is refused. Pension contributions and a mobility/travel allowance are standard and negotiable. Bands are structured; the level is often the real negotiation.
            """
        case .canada:
            return """
            Canada. Base + bonus + RSUs, structured like the US but with tighter ranges and smaller equity grants. Confirm the currency of the offer (CAD vs USD) — for a US company hiring in Canada this is a real difference. RRSP matching, health/dental coverage and extra vacation are legitimate levers when base is capped. Levelling matters as much as the number.
            """
        case .uae:
            return """
            UAE. Income is tax free, so compare net-to-net against any other offer rather than headline gross. Packages are usually quoted monthly and split into basic salary plus housing, transport and other allowances — the split matters because end-of-service gratuity is calculated on BASIC only, so a high allowance / low basic package quietly pays less on exit. Annual flights home, family health insurance, schooling allowance and relocation are all normal asks. Contracts are usually fixed-term; check the notice and end-of-service terms before agreeing on the number.
            """
        case .singapore:
            return """
            Singapore. Base is quoted monthly or annually, plus AWS (the 13th month bonus) and a performance bonus — confirm whether AWS is contractual or discretionary. CPF applies to citizens and PRs and is a real employer cost; for an EP holder there is no CPF, so cash base should reflect that. Employment Pass eligibility ties to a minimum qualifying salary, which can make the base non-negotiable downwards. Relocation, flights and health cover are normal asks.
            """
        case .australia:
            return """
            Australia. The critical question is whether the quoted package includes superannuation (11.5%+) or sits on top of it — the same headline number can differ by a tenth depending on the answer, so ask before responding. Bonuses are modest, equity is rare outside startups and scaleups. Extra leave, flexible/remote days and a salary review at 6 months are realistic levers when the band is fixed.
            """
        case .global:
            return """
            Remote-first / global company. The whole negotiation turns on one question: is the band location-agnostic (same pay everywhere, usually benchmarked to a US or EU tier) or location-adjusted (indexed to where you live)? Ask which one it is and which tier or zone you have been placed in — being moved a tier up is often easier than moving the number inside a tier. Confirm the payroll currency and who carries FX risk, whether you are hired as an employee via an EOR or as a contractor (that changes benefits, leave and taxes entirely), and who pays for equipment, co-working and travel to onsites.
            """
        }
    }
}

// MARK: - Where the work happens

enum WorkSetup: String, CaseIterable, Identifiable {
    case onsite, hybrid, remote
    var id: String { rawValue }

    var label: String {
        switch self {
        case .onsite: return "Office"
        case .hybrid: return "Hybrid"
        case .remote: return "Remote"
        }
    }

    var norms: String {
        switch self {
        case .onsite:
            return "The role is fully in-office. Relocation support, a joining/settling-in allowance, commute or parking, and the start date are all part of the money conversation — if the base is capped, these are where the value is. If a move is involved, price the cost-of-living difference into the ask explicitly rather than accepting the number in isolation."
        case .hybrid:
            return "The role is hybrid. Get the exact number of office days written into the offer letter, not left to a manager's discretion — it is the term most likely to change after joining. Commute cost and time are a real pay cut; it is fair to reflect them in the number or to trade a day of flexibility for it."
        case .remote:
            return "The role is fully remote. Establish whether the band is location-adjusted or location-agnostic before naming any number — that single answer decides whether the market rate is your city's or the company's. Also settle equipment budget, home-office allowance, co-working, travel to onsites, and which country's payroll and leave policy applies."
        }
    }

    // How much of my day the move costs me, roughly ordered — used to work out
    // which direction the change runs.
    private var officeLoad: Int {
        switch self {
        case .remote: return 0
        case .hybrid: return 1
        case .onsite: return 2
        }
    }

    // Giving up remote is one of the strongest honest arguments in a pay
    // conversation, and it is invisible if only the new role's setup is known —
    // so the change itself gets its own block in the prompt.
    static func transitionNorms(from current: WorkSetup, to next: WorkSetup) -> String {
        guard current != next else { return "" }
        let losingFlexibility = next.officeLoad > current.officeLoad

        if losingFlexibility {
            var s = "IMPORTANT — I am giving something up here: I work \(current.spokenNow) today and this role is \(next.spokenRole). That is a real cost, not a preference, and it belongs in the number: commute time and money I do not spend today, and the loss of flexibility I already have and would be handing back. Say it plainly once, without complaining — \"I'd be giving up a fully remote setup for this, so the number has to account for that\" is a clean, honest argument that is hard to push back on. "
            if current == .remote && next == .onsite {
                s += "If a city move is involved, price the cost-of-living difference in explicitly instead of accepting the number as if I still lived where I live now, and ask about relocation support, a settling-in allowance and temporary accommodation. Also worth testing whether a couple of remote days can be written into the offer — that is often cheaper for them to grant than base, and it is the thing I actually lose."
            } else {
                s += "Get the exact office days into the offer letter rather than leaving them to a manager, and put commute cost or transport allowance on the table if the base will not move."
            }
            return s
        }

        return "I work \(current.spokenNow) today and this role is \(next.spokenRole), so I am gaining flexibility. Do not let that become the reason to pay less — the company saves on a desk, not on my work, and \"you will save on the commute\" is not a compensation argument. Take the gain, keep the number where the role is worth, and lock the arrangement in writing so it cannot quietly revert after joining."
    }

    // Phrasings so the two halves of the transition sentence read naturally.
    fileprivate var spokenNow: String {
        switch self {
        case .onsite: return "fully from an office"
        case .hybrid: return "hybrid"
        case .remote: return "fully remotely"
        }
    }

    fileprivate var spokenRole: String {
        switch self {
        case .onsite: return "fully in-office"
        case .hybrid: return "hybrid"
        case .remote: return "fully remote"
        }
    }
}

// MARK: - Who is on the other side

// A founder can decide on the call; a recruiter carries a band they cannot
// break. Same ask, completely different delivery.
enum Counterpart: String, CaseIterable, Identifiable {
    case recruiter, manager, founder
    var id: String { rawValue }

    var label: String {
        switch self {
        case .recruiter: return "Recruiter / HR"
        case .manager:   return "Hiring manager"
        case .founder:   return "Founder / CEO"
        }
    }

    var norms: String {
        switch self {
        case .recruiter:
            return "I am talking to a recruiter or HR. They carry a band and cannot break it, but they control what gets escalated — so the goal is to get the band and the level on the table, stay warm and easy to advocate for, and avoid committing to a number before hearing theirs. Do not argue technical scope with them; that is the hiring manager's currency."
        case .manager:
            return "I am talking to the hiring manager. They are the one who wants me and who has to go fight finance or the founder for the number, so my job is to hand them ammunition: the scope I will own, what I unblock in the first 90 days, and why the level I am asking for is the level of the work. Make it easy for them to argue on my behalf."
        case .founder:
            return "I am talking to the founder or CEO. They own the budget and can decide on this call, so a real number can be agreed live — but they think in runway, ownership and conviction, not in bands and HR process. Frame the ask around the outcomes I take off their plate and the risk I am taking on joining. Corporate HR-speak lands badly here; being direct, brief and clearly committed to the company lands well. Equity, a written review at 6 months, title and scope are all things they can grant on the spot when cash is genuinely tight."
        }
    }
}

// MARK: - Profile

// Everything the negotiation answers are grounded in. Filled in once in Setup —
// before the call, not during it — so a live question only has to be the
// question, and the numbers are already there.
struct NegotiationProfile {
    var country: SalaryCountry = .india
    var currentWork: WorkSetup = .remote   // how I work today
    var work: WorkSetup = .remote          // how the new role works
    var counterpart: Counterpart = .founder
    var role = ""          // title + company/stage
    var years = ""         // years of experience
    var currentPay = ""    // current salary, in local convention
    var benefits = ""      // what the current package includes beyond cash
    var expectedPay = ""   // what I'm asking for
    var leverage = ""      // competing offers, deadlines, constraints

    // Keys are shared with the @AppStorage bindings in SetupView.
    static func load(_ d: UserDefaults = .standard) -> NegotiationProfile {
        var p = NegotiationProfile()
        p.country     = SalaryCountry(rawValue: d.string(forKey: "negCountry") ?? "") ?? .india
        p.currentWork = WorkSetup(rawValue: d.string(forKey: "negWorkNow") ?? "") ?? .remote
        p.work        = WorkSetup(rawValue: d.string(forKey: "negWork") ?? "") ?? .remote
        p.counterpart = Counterpart(rawValue: d.string(forKey: "negCounterpart") ?? "") ?? .founder
        p.role        = d.string(forKey: "negRole") ?? ""
        p.years       = d.string(forKey: "negYears") ?? ""
        p.currentPay  = d.string(forKey: "negCurrentPay") ?? ""
        p.benefits    = d.string(forKey: "negBenefits") ?? ""
        p.expectedPay = d.string(forKey: "negExpectedPay") ?? ""
        p.leverage    = d.string(forKey: "negLeverage") ?? ""
        return p
    }

    // The numbers are what make the advice specific. Without them the mode still
    // works, it just has to coach in ranges — so Setup nags for them, softly.
    var hasNumbers: Bool {
        !currentPay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !expectedPay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Injected into the system prompt for negotiation mode.
    var promptBlock: String {
        var s = """


        === THE MARKET I AM NEGOTIATING IN ===
        \(country.flag) \(country.name) — quote every number in \(country.currency).
        \(country.norms)

        \(work.norms)
        """
        let move = WorkSetup.transitionNorms(from: currentWork, to: work)
        if !move.isEmpty { s += "\n\n\(move)" }
        s += """


        \(counterpart.norms)

        === MY SITUATION — these are the real numbers, never replace them with invented ones ===
        """
        func line(_ label: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return }
            s += "\n\(label): \(v)"
        }
        line("Role on the table", role)
        line("My experience", years)
        line("What I earn today", currentPay)
        line("What my current package includes beyond cash", benefits)
        line("How I work today vs this role",
             currentWork == work ? "\(work.label) — no change"
                                 : "\(currentWork.label) → \(work.label)")
        line("What I want", expectedPay)
        line("My leverage and constraints", leverage)

        if !hasNumbers {
            s += """

            I have not filled in my current or target number yet. Do not invent one for me — work in ranges, and open by asking me the one number you actually need before the rest of the advice can be specific.
            """
        }
        return s
    }
}
