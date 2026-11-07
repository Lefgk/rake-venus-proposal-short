// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IRakeFarm {
    function poolInfo(uint256 pid)
        external
        view
        returns (address want, uint256 allocPoint, uint256 lastRewardBlock, uint256 accAUTOPerShare, address strat);
    function userInfo(uint256 pid, address user) external view returns (uint256 shares, uint256 rewardDebt);
}

interface IFarmStrat {
    function sharesTotal() external view returns (uint256);
}

interface IVTokenClaim {
    function underlying() external view returns (address);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

/// @title RakeDepositorsClaim — 90-day pro-rata claim window for RAKE stuck-pool depositors
/// @notice Deploy with no arguments, BEFORE the Venus rescue. The deployer is the fee recipient
///         (12.5% of what arrives = 10% of the total) and the beneficiary (unclaimed funds after
///         90 days). Only the Venus Normal Timelock can open the window, as the VIP's last action. The farm, the 7 stuck Venus pools
///         (pids 9–15) and the depositor wallets are fixed in code. Nobody types an amount.
///
///         Each wallet's claim is read from the RakeFarm itself: its cut of a token =
///         pool × `FARM.userInfo(pid, wallet).shares` ÷ the strategy's `sharesTotal()` fixed at
///         deploy. The stuck pools' shares cannot grow — every deposit reverts in the strategy
///         (want→vToken allowance is 0 and no function restores it) — so the farm is a frozen,
///         public ledger of who is owed what. Whatever amount of a token arrives is split by
///         those shares, so the payout is right whether the sender takes its cut first or not.
///
/// Lifecycle:
///  1. Deploy. Token (= pool want) and the strategy's total shares are read from the farm and fixed,
///     and the farm shares of every built-in wallet are snapshotted (anyone can `record` a
///     missed wallet later), so a farm withdrawal after the rescue (which burns shares and pays
///     nothing) cannot lower a claim.
///  2. Funds arrive: the Venus rescue moves 80% of each position's net vTokens here.
///  3. In the same VIP, the Timelock calls `open()` as its last action: redeems every vToken to
///     its underlying, takes FEE_BPS of each token to FEE_RECIPIENT, fixes the rest as that
///     token's pool (XVS excepted: its pool grows as XVS arrives), starts the 90-day clock.
///     Funds and opening land in one transaction: nobody can open early (e.g. after sending
///     1 wei of each token) or hold the window back, and `open()` has no balance checks to fail.
///  4. Depositors call `claim()` (all tokens) or `claimToken(token)` (one) — paid only to
///     msg.sender. Per-token flags, so one token that refuses a transfer blocks only itself.
///  5. After the deadline anyone may call `sweep(token)`; everything left goes to BENEFICIARY.
///     Nothing can be swept before the window opens.
///
/// XVS (optional, stays open): Venus may send XVS at any time, in any number of transfers,
/// before or after `open()`. Each arrival is fee'd once and added to the XVS pool; during the
/// window a wallet can claim its share of everything received so far, again after each new
/// arrival. Each pool's slice is weighted by the XVS that pool's strategy earned on Venus:
/// a wallet's cut = XVS pool × Σ(pool weight × wallet shares ÷ total shares) ÷ Σ weights.
/// No XVS, no change.
contract RakeDepositorsClaim {
    address internal constant RAKE_FARM = 0x7f7Bf15B9c68D23339C31652C8e860492991760d;

    uint256 public constant CLAIM_WINDOW = 90 days;

    IRakeFarm public immutable FARM;
    address public immutable BENEFICIARY;
    address public immutable FEE_RECIPIENT;
    uint256 public immutable FEE_BPS;
    address public immutable OPENER; // Venus Normal Timelock: the only caller of open()
    address public immutable XVS; // optional extra token, address(0) = none

    uint256 public openedAt;

    address[] public tokens;
    mapping(address => bool) public isToken;
    mapping(address => uint256) public pidOf; // token => farm pid
    mapping(address => address) public vTokenOf; // token => Venus market whose vTokens arrive here
    mapping(address => uint256) public totalShares; // token => strategy sharesTotal, fixed at deploy
    mapping(address => uint256) public pool; // token => amount split among shares; fixed at open, except XVS (grows as it arrives)
    mapping(address => uint256) public paidOut; // token => amount claimed so far
    mapping(address => mapping(address => bool)) public claimedToken; // wallet => token => claimed
    mapping(address => bool) public recorded; // wallet => shares snapshotted
    mapping(address => mapping(address => uint256)) public snapshot; // wallet => token => shares
    mapping(address => uint256) public xvsWeight; // token => XVS its strategy earned, fixed at deploy
    uint256 public xvsWeightTotal;
    mapping(address => uint256) public xvsPaid; // wallet => XVS claimed so far

    event Recorded(address indexed wallet);
    event Opened(uint256 openedAt, uint256 deadline);
    event FeeTaken(address indexed token, uint256 amount);
    event Claimed(address indexed wallet, address indexed token, uint256 amount);
    event Swept(address indexed token, uint256 amount);

    constructor() {
        uint256[] memory pids = _pids();
        require(pids.length > 0, "no pools");
        address farm = _farm();
        BENEFICIARY = msg.sender;
        FEE_RECIPIENT = msg.sender;
        FEE_BPS = _feeBps();
        OPENER = _opener();
        XVS = _xvs();
        uint256[] memory weights = _xvsWeights();
        require(weights.length == 0 || weights.length == pids.length, "weights length");
        address[] memory vts = _vTokens();
        require(vts.length == 0 || vts.length == pids.length, "vTokens length");
        FARM = IRakeFarm(farm);
        for (uint256 i; i < pids.length; ++i) {
            (address want,,,, address strat) = IRakeFarm(farm).poolInfo(pids[i]);
            require(want != address(0) && strat != address(0), "bad pool");
            require(!isToken[want], "duplicate token");
            isToken[want] = true;
            tokens.push(want);
            pidOf[want] = pids[i];
            if (vts.length > 0) {
                require(IVTokenClaim(vts[i]).underlying() == want, "vToken mismatch");
                vTokenOf[want] = vts[i];
            }
            // Fixed at deploy, BEFORE any rescue runs: a rescue that touches the strategy
            // can leave sharesTotal inflated, so it is never re-read.
            uint256 shares = IFarmStrat(strat).sharesTotal();
            require(shares > 0, "no shares");
            totalShares[want] = shares;
            if (weights.length > 0) {
                xvsWeight[want] = weights[i];
                xvsWeightTotal += weights[i];
            }
        }
        require(XVS == address(0) || (!isToken[XVS] && xvsWeightTotal > 0), "bad xvs setup");
        address[] memory wallets = _wallets();
        bytes memory masks = _poolMasks();
        require(masks.length == 0 || masks.length == wallets.length, "masks length");
        uint256[] memory recordedShares = _record(wallets, masks);
        // Masks only skip reads of pools a wallet holds nothing in. If one were wrong, some
        // shares would go unrecorded; requiring the recorded shares to add up to each
        // strategy's sharesTotal makes that impossible to deploy.
        if (masks.length > 0) {
            for (uint256 j; j < tokens.length; ++j) {
                require(recordedShares[j] == totalShares[tokens[j]], "masks incomplete");
            }
        }
    }

    /// @notice Snapshot wallets' live farm shares, read from the farm itself (nobody types an
    ///         amount). Anyone may call, once per wallet. Record every depositor right after
    ///         deploy, before the rescue: after the rescue `RakeFarm.withdraw` succeeds, pays
    ///         nothing and burns shares, so a live read would let a depositor lose their claim.
    ///         Shares can only fall in these pools, so a snapshot never exceeds what was owed.
    function record(address[] calldata wallets) external {
        _record(wallets, "");
    }

    /// Reads wallet i's shares in pool j only if bit j of masks[i] is set (no masks = every
    /// pool). Returns the shares recorded per pool.
    function _record(address[] memory wallets, bytes memory masks) internal returns (uint256[] memory sums) {
        sums = new uint256[](tokens.length);
        for (uint256 i; i < wallets.length; ++i) {
            address w = wallets[i];
            if (recorded[w]) continue;
            recorded[w] = true;
            uint8 m = masks.length == 0 ? type(uint8).max : uint8(masks[i]);
            for (uint256 j; j < tokens.length; ++j) {
                if (m & (1 << j) == 0) continue;
                (uint256 s,) = FARM.userInfo(pidOf[tokens[j]], w);
                if (s > 0) snapshot[w][tokens[j]] = s;
                sums[j] += s;
            }
            emit Recorded(w);
        }
    }

    /// @notice Redeem, take the fee, fix each token's pool, start the window. Called by the
    ///         Timelock as the VIP's last action, in the transaction that delivers the funds.
    ///         No balance checks: a pool is whatever arrived.
    function open() external {
        require(msg.sender == OPENER, "not opener");
        require(openedAt == 0, "already open");
        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[i];
            _redeemAll(t);
            uint256 bal = _balance(t);
            uint256 fee = bal * FEE_BPS / 10_000;
            if (fee > 0) {
                _safeTransfer(t, FEE_RECIPIENT, fee);
                emit FeeTaken(t, fee);
            }
            pool[t] = bal - fee;
        }
        openedAt = block.timestamp;
        _syncXvs(); // XVS is optional: whatever is here now is pooled, more can follow
        emit Opened(block.timestamp, block.timestamp + CLAIM_WINDOW);
    }

    // ─────────────────────────────────── claim window ───────────────────────────────────

    /// @notice Withdraw msg.sender's cut of every token not yet claimed, to msg.sender.
    function claim() external {
        _requireWindow();
        bool any;
        for (uint256 i; i < tokens.length; ++i) {
            if (_claimOne(msg.sender, tokens[i])) any = true;
        }
        if (XVS != address(0)) {
            _syncXvs();
            if (_claimXvs(msg.sender)) any = true;
        }
        require(any, "nothing to claim");
    }

    /// @notice Withdraw msg.sender's cut of one token. Lets a wallet take its other tokens if
    ///         one token refuses a transfer to it.
    function claimToken(address token) external {
        _requireWindow();
        if (token == XVS && token != address(0)) {
            _syncXvs();
            require(_claimXvs(msg.sender), "nothing to claim");
        } else {
            require(_claimOne(msg.sender, token), "nothing to claim");
        }
    }

    // ─────────────────────────────────── after deadline ───────────────────────────────────

    /// @notice Send the full remaining balance of `token` to BENEFICIARY. Anyone may call after
    ///         the claim window closes; never before the window opens.
    function sweep(address token) external {
        require(openedAt != 0, "not open");
        require(block.timestamp > openedAt + CLAIM_WINDOW, "window open");
        uint256 amt = _balance(token);
        require(amt > 0, "nothing to sweep");
        _safeTransfer(token, BENEFICIARY, amt);
        emit Swept(token, amt);
    }

    // ─────────────────────────────────────── views ───────────────────────────────────────

    /// @notice A wallet's shares in the pool behind `token`: its snapshot if recorded,
    ///         otherwise its live farm shares.
    function sharesOf(address wallet, address token) public view returns (uint256 shares) {
        if (!isToken[token]) return 0;
        if (recorded[wallet]) return snapshot[wallet][token];
        (shares,) = FARM.userInfo(pidOf[token], wallet);
    }

    /// @notice What `wallet` can claim of `token` right now. Before open this is an estimate
    ///         from the current balance after the fee; after open it is exact.
    function claimable(address wallet, address token) external view returns (uint256) {
        if (openedAt != 0 && block.timestamp > openedAt + CLAIM_WINDOW) return 0; // window closed
        if (token == XVS && token != address(0)) {
            return _xvsShare(wallet, _xvsPoolNow()) - xvsPaid[wallet];
        }
        if (!isToken[token] || claimedToken[wallet][token]) return 0;
        if (openedAt != 0) return _cut(wallet, token);
        uint256 bal = _balance(token);
        address v = vTokenOf[token];
        if (v != address(0)) bal += _balance(v) * IVTokenClaim(v).exchangeRateStored() / 1e18;
        return (bal - bal * FEE_BPS / 10_000) * sharesOf(wallet, token) / totalShares[token];
    }

    /// @notice True once `wallet` has claimed every token it holds shares in.
    function claimedAll(address wallet) external view returns (bool) {
        bool listed;
        for (uint256 i; i < tokens.length; ++i) {
            if (sharesOf(wallet, tokens[i]) == 0) continue;
            listed = true;
            // A dust holding whose cut rounds to 0 has nothing to claim, so it counts as done.
            if (!claimedToken[wallet][tokens[i]] && (openedAt == 0 || _cut(wallet, tokens[i]) > 0)) return false;
        }
        if (listed && XVS != address(0) && _xvsShare(wallet, _xvsPoolNow()) > xvsPaid[wallet]) return false;
        return listed;
    }

    function deadline() external view returns (uint256) {
        return openedAt == 0 ? 0 : openedAt + CLAIM_WINDOW;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    // ───────────────────────────────────── internals ─────────────────────────────────────

    function _requireWindow() internal view {
        require(openedAt != 0, "not open");
        require(block.timestamp <= openedAt + CLAIM_WINDOW, "window closed");
    }

    /// Effects before the transfer: the flag is set first, so a re-entry finds nothing.
    function _claimOne(address wallet, address token) internal returns (bool) {
        if (!isToken[token] || claimedToken[wallet][token]) return false;
        uint256 amt = _cut(wallet, token);
        if (amt == 0) return false;
        claimedToken[wallet][token] = true;
        // Hard cap: even if farm shares were ever to change, no token pays out past its pool.
        require(paidOut[token] + amt <= pool[token], "pool exhausted");
        paidOut[token] += amt;
        _safeTransfer(token, wallet, amt);
        emit Claimed(wallet, token, amt);
        return true;
    }

    /// Rounds down, so the sum of all cuts never exceeds the pool; dust is swept at the end.
    /// Turns whatever vTokens of `token`'s market are here into `token`.
    function _redeemAll(address token) internal {
        address v = vTokenOf[token];
        if (v == address(0)) return;
        uint256 vBal = _balance(v);
        if (vBal == 0) return;
        // Venus vTokens return an error code instead of reverting.
        require(IVTokenClaim(v).redeem(vBal) == 0, "redeem failed");
    }

    /// The XVS pool including any not-yet-pooled arrival, net of its fee.
    function _xvsPoolNow() internal view returns (uint256) {
        uint256 bal = _balance(XVS);
        uint256 unpaid = pool[XVS] - paidOut[XVS];
        uint256 unpooled = bal > unpaid ? bal - unpaid : 0; // 0 once swept
        return pool[XVS] + unpooled - unpooled * FEE_BPS / 10_000;
    }

    /// Pool any XVS that arrived since the last sync: fee'd once, then added to the pool.
    function _syncXvs() internal {
        uint256 bal = _balance(XVS);
        uint256 unpaid = pool[XVS] - paidOut[XVS];
        if (bal <= unpaid) return;
        uint256 arrived = bal - unpaid;
        uint256 fee = arrived * FEE_BPS / 10_000;
        if (fee > 0) {
            _safeTransfer(XVS, FEE_RECIPIENT, fee);
            emit FeeTaken(XVS, fee);
        }
        pool[XVS] += arrived - fee;
    }

    /// Pays the wallet's share of all XVS pooled so far, minus what it already took.
    function _claimXvs(address wallet) internal returns (bool) {
        uint256 amt = _xvsShare(wallet, pool[XVS]) - xvsPaid[wallet];
        if (amt == 0) return false;
        xvsPaid[wallet] += amt;
        require(paidOut[XVS] + amt <= pool[XVS], "pool exhausted");
        paidOut[XVS] += amt;
        _safeTransfer(XVS, wallet, amt);
        emit Claimed(wallet, XVS, amt);
        return true;
    }

    function _cut(address wallet, address token) internal view returns (uint256) {
        uint256 total = totalShares[token];
        if (total == 0) return 0;
        uint256 shares = sharesOf(wallet, token);
        if (shares > total) shares = total;
        return pool[token] * shares / total;
    }

    /// `amount` × the wallet's XVS-weighted share across all pools. Rounds down; per pool the
    /// shares sum to at most the total, so all wallets together never exceed `amount`.
    function _xvsShare(address wallet, uint256 amount) internal view returns (uint256) {
        if (amount == 0 || xvsWeightTotal == 0) return 0;
        uint256 acc;
        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[i];
            uint256 w = xvsWeight[t];
            if (w == 0) continue;
            uint256 shares = sharesOf(wallet, t);
            if (shares == 0) continue;
            uint256 total = totalShares[t];
            if (shares > total) shares = total;
            acc += w * shares * 1e18 / total;
        }
        return amount * acc / (xvsWeightTotal * 1e18);
    }

    function _balance(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        require(ok && ret.length >= 32, "balanceOf failed");
        return abi.decode(ret, (uint256));
    }

    /// Tolerates the non-standard ERC-20s that return nothing instead of a bool.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transfer failed");
    }

    // ──────────────────────────────── built-in RAKE setup ────────────────────────────────

    /// @notice The depositor list compiled into this contract, for anyone to check.
    function builtInWallets() external view returns (address[] memory) {
        return _wallets();
    }

    /// Venus Normal Timelock, admin of all seven markets: the VIP runs through it.
    function _opener() internal view virtual returns (address) {
        return 0x939bD8d64c0A9583A7Dcea9933f7b21697ab6396;
    }

    function _farm() internal view virtual returns (address) {
        return RAKE_FARM;
    }

    /// Venus keeps 20% and sends 80%. 12.5% of the 80% that arrives = 10% of the total.
    function _feeBps() internal view virtual returns (uint256) {
        return 1_250;
    }

    function _xvs() internal view virtual returns (address) {
        return 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    }

    /// XVS each strategy earned on Venus (claimable into it, measured at head; see
    /// XVS_AND_RAKE_TOKEN_ANALYSIS.md §B.1), in pid order. Only the RATIOS matter.
    function _xvsWeights() internal view virtual returns (uint256[] memory w) {
        w = new uint256[](7);
        w[0] = 1_886_830984181666840490; // vBUSD
        w[1] = 1_423_434946913568498108; // vBTC
        w[2] = 2_024_614489487491287432; // vETH
        w[3] = 480_752331423775516479; //   vLINK
        w[4] = 421_025235115653350064; //   vUSDT
        w[5] = 1_706_444103494049200495; // vUSDC
        w[6] = 78_888707861071323767; //    vDOT
    }

    /// vBUSD, vBTC, vETH, vLINK, vUSDT, vUSDC, vDOT
    /// The Venus markets of pids 9–15, in pid order: vBUSD, vBTC, vETH, vLINK, vUSDT, vUSDC, vDOT.
    function _vTokens() internal view virtual returns (address[] memory v) {
        v = new address[](7);
        v[0] = 0x95c78222B3D6e262426483D42CfA53685A67Ab9D;
        v[1] = 0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B;
        v[2] = 0xf508fCD89b8bd15579dc79A6827cB4686A3592c8;
        v[3] = 0x650b940a1033B8A1b1873f78730FcFC73ec11f1f;
        v[4] = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
        v[5] = 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8;
        v[6] = 0x1610bc33319e9398de5f57B33a5b184c806aD217;
    }

    function _pids() internal view virtual returns (uint256[] memory p) {
        p = new uint256[](7);
        for (uint256 i; i < 7; ++i) p[i] = 9 + i;
    }

    /// One byte per wallet in _wallets() order: bit j set = holds shares in pids[j]
    /// (bit 0 BUSD … bit 6 DOT). 146 reads instead of 721; checked in the constructor.
    function _poolMasks() internal view virtual returns (bytes memory) {
        return hex"01022102020120310121100210010104020121114004067b04011020017f02402210200310030101022040100410184004010650043010204401022001200110022604310101104a01020201202111010110040122103011201002021742040101012004204830";
    }

    /// Every wallet holding shares in pids 9–15 (from RakeFarm Deposit/Withdraw history).
    /// Complete: on BSC mainnet the recorded shares sum to each strategy's sharesTotal.
    function _wallets() internal view virtual returns (address[] memory w) {
        address[103] memory a = [
            0x0249E4CDE13647c0d7C21Be66401c45EB448fD08,
            0x0282e055D3b2f7c0AD656952Ac1bB989FB6D0086,
            0x02a50E0aE5e8B53253Cd35FB869640371AEE3D85,
            0x037ea234207D23A14d1c155fd58B57655A338a17,
            0x0612dEE3CfEa2466710A2E36833f85113F6F2BeC,
            0x0Ff0780b031c29557262149b44876560c34BA1AA,
            0x14375581e079fbB4c3C39b65dDbef3f2FA7Bbeea,
            0x14Ff0Bc9417B6796f79768729002A793b51205B8,
            0x150663582908475704F6c427800d6738c4ac1f5a,
            0x1a4b77aa33f0fcbde2f1a6bDad2004cF938c34B0,
            0x1dEE55791aca3d6C1Bb3f6055166e0699C58DFB3,
            0x1e95B952165fE604fb76b37923b7112107F9531e,
            0x1FAdCC298c59Cdf45483ee291F545a2BEd47AfCE,
            0x22C72Dd0223854FDAf5b869FF8d0d3B29701c5Bc,
            0x2A5ba6819249aa93c0ad8711a9F8058360083Fb7,
            0x2A8e0ebDA46A075D77d197D21292e38D37a20AB3,
            0x2B5D6b9b94d3D38DAda1aF420bA4Bcc110926508,
            0x2B8a1C2C1B1A274C5Cb88CFf1217dA8c44b0228D,
            0x2d074D5eeF19299A72C90Ba8f8114F0d3123b022,
            0x2F9994048EE63271f5beB337C902B74B93A0136A,
            0x2f9cdF66452Eb4F4cf6734791960201cE923a78b,
            0x36AA851A91Dd5C2a57067FF28C17Bd36c38b3131,
            0x3F6BaBbF1a9DFB3039Dc932986D4A9658234fe21,
            0x40A3c250F49e956e59F7c159C0d1BE89F157BcA3,
            0x434485B50d13dC2ff7E3D297c2EE24cdCbE90d11,
            0x46B9A06881EF2c996934F32B7849F02394Fb09Be,
            0x50033dA094fcf2985a1B4Bb7ff6DF5e8C5E625C1,
            0x5485dAC30911d3BBE51bC61b84f723160379D49f,
            0x595E7FfbD1d59f718fC67a398A9F9D506a68836c,
            0x5984bb82F11171cb1DC2287E2A6935c44D491538,
            0x5c612b240a0F5757529D7d34C726168aeBeDBc74,
            0x5FCD606f8a8da76601F27F932588e892633d43Ae,
            0x6093eF2F5B206fFF2171af5bef2C506eDB200470,
            0x6107a166a4243dA3012916Dd6a6eF52b165F0E30,
            0x63Cf8d4899509F12d9f22FAF346d64D9e5D36d9d,
            0x63F06788670D8FE1e8994f88029b611B7A63821A,
            0x64368FAce21029A646d823c0AFcBB4dA08Ce9b78,
            0x64653Ae9BB31C838c86c291c34DdE65201fECaDe,
            0x662F6ef2092c126b6EE0Da44e6B863f30971880d,
            0x667cBbEd2E1295EC25381e2b056547eb90FC8F96,
            0x6990f87dc2BfFbd9A52694b1d3d963F62Cd09eB7,
            0x6A00902C02d81671B106439A214A7dD0cA08C504,
            0x6bdf6D03328e04Cf4E5079eA347e0c413AfcdF63,
            0x6cF38a81dC0cfa464aaEF0a6f7E0a62600054BE1,
            0x6df9291b701cc540a08B8dF2B4c2e5a660A2C9a3,
            0x6F69DfaE189aD285CAb4cEC165c360CCf05Ffa6a,
            0x70F65a050DDf1AF785cABe1dC658809851003699,
            0x729430b72a5f8C51d4149ab7b65Cc9E3731DB330,
            0x79d741071E819f8ae5884FA056FA62c94B144895,
            0x8271eF8441733D8543320830582982Cb4B115fC3,
            0x82822D21f7b4E17d1b12d07d7B7664924bC64E3b,
            0x8757fc1A9e21E17620a95BF42D8765439c5dbc8F,
            0x889c97ad4157B802b1e34b0120B49a6eDF6c6F0a,
            0x88f7C87d92673038FCE0d187bA0D365F3bC9aA1A,
            0x8Cda99F7f138f77b5A69e584637651604d511bc4,
            0x926C5be9A0c755584FeF616fcD7d05fB791b05Cd,
            0x93f5af632Ce523286e033f0510E9b3C9710F4489,
            0x9D1105e9232ad98C4bECF027B56d3f087CCEa5b6,
            0x9E3781496917F5feDaB2d4ECD5c7b1047c8de1Bc,
            0x9fCFdB8158e982E9d3E3Cf9C9D29E9d4b1C75bc5,
            0x9Fd8313CfCd184ea1Eb70bF2baC8F9bfB07E6E37,
            0xA1B6C6FF990B6E086421ffeab6595EFBFf11B942,
            0xA2447A15D925d74Ce2e029A1482C611f7ee7c9Fb,
            0xa254b20e9Ff813FD78B15436388eC680af788C04,
            0xa4517a2B21f85f6a6a63601Cea7fa4E34da92856,
            0xA63Bca4aa47e42498889AB5185336FEa54835C7E,
            0xAa9E20bAb58d013220D632874e9Fe44F8F971e4d,
            0xAe4C7F2B914b7DfCD5E1d22D30b4325910aA709E,
            0xAF1bff74708098dB603e48aaEbEC1BBAe03Dcf11,
            0xAFC1a5cB605bBd1aa5F6415458BC45cD7554d08b,
            0xb03e25C2c3731a377B259B84deBe451e2d1Ff4c2,
            0xB0dE8CB21cf560373cfF609536688ca77Da67375,
            0xb160157643C08b92Cc9c5e0A36Ee2724A35D7e3f,
            0xB2e4BC35B4934C3966e2C3ED267710e0707c6ac7,
            0xB4d39242F35bdD370908dE3AC2630Db3bc4c8C64,
            0xb871CC92B9Aa9c91912e6A9EBcC10aD19C4a7bfF,
            0xba05F4A3639EBcDf1e9Ea8Bb8C0a00f3511b97ce,
            0xBB689DC15F7B1286CB1f3dFCC72BF5A627b63022,
            0xbB9Fb6eca452c87e8Eb24d4F62739E0980cFAafC,
            0xBBc0AAf3f7648a4A63d8D8960489cB491FDcb693,
            0xbe1dc9507916208bb449c64b39d76270B6FE2F09,
            0xc0C54eA31065C46cd97e2918b5ad32BF220ec97d,
            0xc0ffee008Fbe30dB8116BBcf1BF8a94c9c044647,
            0xc21b473CCFcB45D2A9dd40d8ee82F873A724eE73,
            0xC2AD5F27534853008450876A2Cc5225AD5513695,
            0xc2F249642D3c7bCf1380CcC20374c0f516d2f8fE,
            0xC443D816a011D720DC8f3dD69390B16554ff2A3B,
            0xCfB76E48D9C7215885D5DE6279f942C9c01F62D4,
            0xd7F5fB2deb6A4c77E753e19f93EE04c787f66BC6,
            0xdE72C289E2856D902529F3c397b4c04C6Ec1f0D7,
            0xdEd759cCEb9De9C47A5FFeaE6FA4E5E4fCe46C95,
            0xdF8d73dB2e4756F051DeCb67C0d14C44c73a6112,
            0xe24C2133714B735f7dFf541d4Fb9a101C9aBcb40,
            0xe728B4C63Dd8f0a6d684d12353F460D7c75af524,
            0xe9F7C9B6c706a01876Fd6ac9D81701CB7B8Da863,
            0xEf9D67DB3d19f7C324473435613F3335F515b2AE,
            0xF05e0c0a95e22023d1BF8Fa1843598eF49f3143e,
            0xf1755E953257e0019D8ce5A1dba79d1E69F175C6,
            0xF5f2281e7bb4e22e0e23CD8b69Ae2d0956210936,
            0xf87Dd48055CF61F6eeb067fB14412dFe1fA4c7bd,
            0xf9cB49B279FE4733302C41D957Fda72B2e6b3c22,
            0xFDbfabB81AF4ee7c8e240bFf5e0028e1c10Bd5fe,
            0xFFFFF6E70842330948Ca47254F2bE673B1cb0dB7
        ];
        w = new address[](a.length);
        for (uint256 i; i < a.length; ++i) w[i] = a[i];
    }
}
