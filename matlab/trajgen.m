function [traj, durations, problem, exitflag] = trajgen(waypoints, options, bounds)
% function [traj, durations, problem, exitflag] = trajgen(waypoints, options, bounds, varargin)
%
% options is a cell array formatted {'parameter1', value1, 'parameter2', value2, ...}
%
% Available parameters for the options cell array:
%   order (integer)
%       Defines the order of polynomials to use
%   minderiv (vector)
%       Defines which derivative to minimize for each dimension
%   constraints_per_seg (integer)
%       The number of constraints to place for a bound over each segment
%   numerical (boolean)
%       Use the numerical optimization?  Alternative is analytical, but
%       can only be used if there are no bounds.
%   convergetol (double)
%       The tolerance between the primal and dual costs before calling the
%       solution optimal.
%   contderiv (vector)
%       Similar to minderiv, but allows for a different level of required
%       continunity constraints.  For example, [3, 3], would mean that up
%       through the 2nd derivative must be continuous for both dimensions.
%
% The output traj contains a field poly such that
% The first dimension indexes the polynomial coefficients
% The second dimension indexes the dimension of the system (e.g. x, y, z, psi, ...)
% The third dimension indexes the segment
% The fourth dimension indexes the derivative.
%
% So, traj.poly(:, b, c, d) will return the polynomial defining the b^th
% dimension, the c^th segment, and the (d-1)^th derivative.
%
% A more detailed explanation of this program will go here

warning off MATLAB:nearlySingularMatrix
ticker = tic; %#ok<NASGU>

% Initalize return variables
traj = [];
problem = [];

%% Defaults

if nargin < 3 || isempty(bounds)
    % Use the analytical solver
    bounds = [];
    numerical = false;
else
    % Use a numerical solver
    numerical = true;
end

n = 12;      % Polynomial order
constraints_per_seg = 2*(n+1);   % Number of inequality constraints to enforce per segment
convergetol = 1e-08;    % Tolernce

verbose = true;

%% Process varargin
for idx = 1:2:length(options)

    switch options{idx}
        case 'order'
            n = options{idx+1};
        case 'minderiv'
            % What derivative are we minimizing
            % minderiv = 4 corresponds to snap
            % minderiv = 2 corresponds to acceleration
            % minderiv = 0 corresponds to position
            minderiv = max(0,options{idx+1});

            % The highest derivative which must be continuous
            if ~exist('contderiv', 'var')
                contderiv = minderiv;
            end

            if max(minderiv) > 4; warning('This program can only support up to 4 derivatives at this time.'); end; %#ok<WNTAG>

            % We can also determine the number of dimensions
            d = length(minderiv);

        case 'constraints_per_seg' % #### This should be a shorter argument...
            constraints_per_seg = options{idx+1};
        case 'numerical'
            numerical = options{idx+1};
        case 'convergetol'
            convergetol = options{idx+1};
            sprintf(['\033[;33m Setting convergetol = ', num2str(convergetol)]);
        case 'contderiv'
            contderiv = max(0,options{idx+1});
        case 'ndim'
            ndim = options{idx+1};
        case 'verbose'
            verbose = options{idx+1};
    end
end

%% Inline Functions

vprintf = @(str, varargin) fprintf(str(1:verbose*end), varargin{:});

%% Checks

if ~exist('contderiv', 'var')
    contderiv = minderiv;
end

assert(exist('ndim', 'var') == 1, 'The ndim option must be specified.');
assert(length(contderiv) == length(minderiv), 'contderiv and minderiv must be the same length.')
assert(all(diff([waypoints.time]) > 0), '[waypoints.time] must be monotonically increasing.');

% Should check to make sure that length(bounds(:).arg) is consistent

%% 

decoupled = ...
    ndim > 1 && isempty(bounds) || ...
    ndim > 1 && all(strcmp({bounds.type}, 'lb') | strcmp({bounds.type}, 'ub'));

if decoupled
    % In this case, all dimensions are decoupled. Let's call trajgen for
    % each one to simplify the solution.
    
    traj = cell(ndim, 1);
    wp = waypoints;
    for didx = 1:ndim
        
        new_options = options;
        new_options{find(strcmp(options, 'ndim')) + 1} = 1;
        
        minderiv_idx = find(strcmp(options, 'minderiv')) + 1;
        new_options{minderiv_idx} = options{minderiv_idx}(didx);
        
        contderiv_idx = find(strcmp(options, 'contderiv')) + 1;
        new_options{contderiv_idx} = options{contderiv_idx}(didx);
        
        for wpidx = 1:length(waypoints)
            wp(wpidx).time = waypoints(wpidx).time;
            wp(wpidx).pos = waypoints(wpidx).pos(didx);
            wp(wpidx).vel = waypoints(wpidx).vel(didx);
            wp(wpidx).acc = waypoints(wpidx).acc(didx);
            wp(wpidx).jerk = waypoints(wpidx).jerk(didx);
            wp(wpidx).snap = waypoints(wpidx).snap(didx);
        end
        
        new_bounds = bounds;
        for bidx = 1:length(new_bounds)
            new_bounds(bidx).arg = new_bounds(bidx).arg(didx);
        end
        
        [dim_traj, durations, problem, dim_exitflag] = trajgen(wp, new_options, new_bounds);
        traj{didx} = dim_traj;
        
        if (dim_exitflag ~= 1)
            warning(['Dimension ' num2str(didx), ' did not converge and had an exit flag of ', num2str(dim_exitflag)]);
        end
        exitflag(didx) = dim_exitflag; %#ok<AGROW>
    end
    return;
end

%% Keytimes, Segments

% We have one less segment than we have waypoints
N = size(waypoints,2) - 1;

keytimes = [waypoints.time]; % Keytimes
durations = diff(keytimes);

%% Generate our linear differential operator

D = differential_linear_operators(n);

%% Equality constraints

% This will make sure that all the waypoints are column vectors
for idx = 1:length(waypoints)
    waypoints(idx).pos = waypoints(idx).pos(:);
    waypoints(idx).vel = waypoints(idx).vel(:);
    waypoints(idx).acc = waypoints(idx).acc(:);
    waypoints(idx).jerk = waypoints(idx).jerk(:);
    waypoints(idx).snap = waypoints(idx).snap(:);
end

% count = 0;
% idx = 0;
% while true
%     idx = idx + 1;
%     if idx + 1 > length(waypoints)
%         break;
%     end
%     
%     t = waypoints(idx).time;
%     dt = waypoints(idx+1).time - t;
%     if dt > 1
%         waypoints = [waypoints(1:idx), NanWaypoint(t + dt/2, d), waypoints(idx+1:end)];
%         count = count + 1;
%     end
% end
% disp([num2str(count) ' waypoints added']);

% Determine the size of E for preallocation.  There will be a row for every
% non-NaN and non-empty constraint.  This will also generate an error if
% the dimensions of the waypoints are not consistent
% (i.e. d is the not the same size for all waypoints)
nrows = sum(sum(~isnan([...
    [waypoints.pos],...
    [waypoints.vel],...
    [waypoints.acc],...
    [waypoints.jerk],...
    [waypoints.snap]])));

% Preallocate E and Ebeq
E = zeros(nrows,d*N*(n+1));
Ebeq = zeros(nrows,1);

% Initalize a row index for E and Ebeq
row = 1;

% And now populate E with the appropriate bases
for pt = 1:N+1
    % The matrix E will have 1 row for every constraint.
    % Additionally, it will have d*N*(n+1) columns.
    % Before each basis group (bgroup) in each row, there will be
    % ((idx - 1) + d*(seg-1))*(n+1) zeros where idx indexes the output (d)
    % and seg indexes the polynomial segment (N).  Then, we know the basis
    % will occupy (n+1) columns.  Finally, the resulting number of zeros is
    % simply the difference of the total columns in the row and the already
    % occupied columns.

    % We need to make the last waypoint fall on the end of the last
    % segment, not the beginning of the next segment.
    bgroup = min(pt,N);

    % Determine the time duration of the segment
    dt = durations(bgroup);

    % We want to scale the time so that each segment is parametrized by t = 0:1.
    % Then, at the beginning of each segment, t = 0, and at the end, t = 1.
    t = pt - bgroup;

    % Now, establish the constraints
    if ~isempty(waypoints(pt).pos)
        deriv = 0;
        temp = basis(t,deriv,n,D);
        for idx = 1:d
            if ~isnan(waypoints(pt).pos(idx)) && (deriv <= contderiv(idx))
                startidx = ((idx-1)+d*(bgroup-1))*(n+1)+1;
                E(row,startidx:startidx+n) = temp;
                Ebeq(row) = waypoints(pt).pos(idx);
                row = row+1;
            end
        end
    end

    if ~isempty(waypoints(pt).vel)
        deriv = 1;
        temp = basis(t,deriv,n,D);
        for idx = 1:d
            if ~isnan(waypoints(pt).vel(idx)) && (deriv <= contderiv(idx))
                startidx = ((idx-1)+d*(bgroup-1))*(n+1)+1;
                E(row,startidx:startidx+n) = temp;
                Ebeq(row) = waypoints(pt).vel(idx)*dt;
                row = row+1;
            end
        end
    end

    if ~isempty(waypoints(pt).acc)
        deriv = 2;
        temp = basis(t,deriv,n,D);
        for idx = 1:d
            if ~isnan(waypoints(pt).acc(idx)) && (deriv <= contderiv(idx))
                startidx = ((idx-1)+d*(bgroup-1))*(n+1)+1;
                E(row,startidx:startidx+n) = temp;
                Ebeq(row) = waypoints(pt).acc(idx)*dt^2;
                row = row+1;
            end
        end
    end

    if ~isempty(waypoints(pt).jerk)
        deriv = 3;
        temp = basis(t,deriv,n,D);
        for idx = 1:d
            if ~isnan(waypoints(pt).jerk(idx)) && (deriv <= contderiv(idx))
                startidx = ((idx-1)+d*(bgroup-1))*(n+1)+1;
                E(row,startidx:startidx+n) = temp;
                Ebeq(row) = waypoints(pt).jerk(idx)*dt^3;
                row = row+1;
            end
        end
    end

    if ~isempty(waypoints(pt).snap)
        deriv = 4;
        temp = basis(t,deriv,n,D);
        for idx = 1:d
            if ~isnan(waypoints(pt).snap(idx)) && (deriv <= contderiv(idx))
                startidx = ((idx-1)+d*(bgroup-1))*(n+1)+1;
                E(row,startidx:startidx+n) = temp;
                Ebeq(row) = waypoints(pt).snap(idx)*dt^4;
                row = row+1;
            end
        end
    end
end

%% Continuity constraints

% There will be the same number of columns as in the matrix E, but now
% there will be a continunity constraint for each output that has a
% derivative below the one we are minimizing.

% There will be a continunity constraint (except for the first and last points)
% for each output and its derivatives up to the continuous one.
nrows = sum((N-1)*(contderiv+1));
C = zeros(nrows,d*N*(n+1));

% This will be zeros since we have
% basis' * coeffs1 - basis' * coeffs2 = 0
Cbeq = zeros(nrows,1);

% Initalize our row counter
row = 1;

% And now populate C with the appropriate bases
for pt = 2:N
    % The matrix C will have 1 row for every constraint.
    % Additionally, it will have d*N*(n+1) columns.
    % Before each basis group (bgroup) in each row, there will be
    % ((idx - 1) + d*(pt-1))*(n+1) zeros where idx indexes the output (d)
    % and pt indexes the polynomial segment (N).  Finally, we know the basis
    % will occupy (n+1) columns.

    % The first group will be one less than the point.  For example, for
    % the continunity constraints at waypoint 2, we will require
    % equivalency between groups 1 and 2.
    bgroup = pt - 1;

    % Extract the durations of the two segments
    dt1 = durations(bgroup);
    dt2 = durations(bgroup + 1);

    % Loop through the derivatives
    for deriv = 0:max(contderiv)

        % Determine our bases at this timestep and for this derivative
        % basis1 corresponds to the end of the first segment and basis0
        % corresponds to the beginning of the next segment
        basis1 = basis(1, deriv, n, D);
        basis0 = basis(0, deriv, n, D);

        % Since we can't scale our constraints, we need to scale our bases
        % since they are on different timescales
        basis1 = basis1./(dt1^(deriv));
        basis0 = basis0./(dt2^(deriv));

        % Now loop through the dimensions
        for idx = 1:d

            % We don't want to impose continunity on derivatives higher
            % than contderiv
            if deriv <= contderiv(idx)

                % The first basis group starts here
                startidx = ((idx-1)+d*(bgroup-1))*(n+1)+1;
                C(row,startidx:startidx+n) = basis1;

                % The second basis group starts (n+1)*d columns later
                startidx = startidx + (n+1)*d;
                C(row,startidx:startidx+n) = -basis0; % Note the negative sign

                % Advance to the next row
                row = row+1;
            end
        end
    end
end

%% The H Matrix

% Initalize H
H = zeros(N*d*(n+1));

% Determine the powers
powers = (n:-1:0)';

% Determine the Base Hpow matrix (this does not need to be recalculated for
% each flat output and segment)
Hpow_base = repmat(powers,1,n+1)+repmat(powers',n+1,1);

% Initalize our row indexes
rows = 1:(n+1);

% Loop through the segments
for seg = 1:N

    % Loop through the dimensions
    for dim = 1:d

        % Generate a matrix which represents the powers of H
        Hpow = Hpow_base-2*minderiv(dim);

        % Determine the coefficients
        if ~isequal(minderiv(dim),0)
            Hcoeffs = (sum(D{minderiv(dim)}).'); %./(durations(seg).^minderiv(dim))
            Hcoeffs = Hcoeffs*Hcoeffs';
        else
            Hcoeffs = ones(n+1);
        end

        % Now integrate
        Hpow(Hpow >= 0) = Hpow(Hpow >= 0) + 1;
        Hcoeffs(Hpow > 0) = Hcoeffs(Hpow > 0)./Hpow(Hpow > 0);

        % Things with negative powers are actually zero.
        Hcoeffs(Hpow < 0) = 0;
        Hpow(Hpow < 0) = 0;

        % And store this block in H
        H(rows,rows) = Hcoeffs; %.*(durations(seg).^Hpow);

        % Now increment to the next diagonal block
        rows = rows + (n+1);

    end
end

%% Inequality constraints
% A*x <= b

% Determine number of rows for preallocation and determine our times.  We
% will also split up bounds by the segment.  For example, a bound that
% lasts the entire duration will be split up into N bounds so that they can
% be more easily processed later.
nrows = 0;
idx = 0;

while (1)
    idx = idx + 1;

    % If we have exceeded the length of bounds, then exit this loop
    if idx > length(bounds)
        break;
    end

    % Let's work with a nicer variable
    t = bounds(idx).time;

    % If the time is empty, then apply the bound for the entire duration
    if isempty(t)
        t = keytimes([1 end]);
    end

    % Determine the segments which the bound starts and finishes in. But,
    % first some bound checking.
    if any(t < min(keytimes)) || any(t > max(keytimes))
        error('You must specify bounds within your keytimes.');
    end
    
    % This could probably be more elegant.
    if t(1) == keytimes(1)
        start_seg = 1;
    elseif t(end) == keytimes(end)
        start_seg = length(keytimes) - 1;
    else
        start_seg = find(keytimes <= t(1), 1, 'last');
    end
    
    if isempty(start_seg) || start_seg > length(keytimes)
      error('Not sure how this happened.');
    end
    
    % If we want it at one instant in time
    if length(t) == 1
        t(2) = t(1);
        end_seg = start_seg;
    else
        end_seg = find(keytimes < t(2), 1, 'last');
    end

    if (start_seg < 1 || start_seg > length(keytimes) - 1 || end_seg > length(keytimes) || end_seg < start_seg)
      keyboard
    end

    % If the bound spans more than one segment, split it up
    if ~isequal(start_seg, end_seg)

        % Copy the current constraint to the end of our bound array
        bounds(end+1) = bounds(idx); %#ok<AGROW>

        % Remove the current segment from the time span
        bounds(end).time = [keytimes(start_seg+1) t(2)];

        % Only consider the current segment for the current bound
        t = [t(1) keytimes(start_seg + 1)];
    end

    % Now generate the times at which this constraint will be applied
    tstep = (keytimes(start_seg+1) - keytimes(start_seg)) / constraints_per_seg;
    t = t(1):tstep:t(2);

    % And store it back in bounds
    bounds(idx).time = t;

    % And store the segment which contains this bound
    bounds(idx).seg = start_seg;

    % The number of dimensions bounded by this bound over this duration
    if ~isequal(length(bounds(idx).arg),d)
        warning('You must specify NaNs for a dimension even if you are not using it in your bound'); %#ok<WNTAG>
    end
    ndim = sum(~isnan(bounds(idx).arg));

    % Keep track of the number of rows we will need
    nrows = nrows + length(t)*ndim;
end

% The powers which we divide the basis by to scale it to the full scale
tpow = (n:-1:0);

% Initalize Aineq and bineq
Aineq = zeros(nrows,N*(n+1)*d);
bineq = zeros(nrows,1);

% Initalize our row counter
rows = 0;

% Loop through the bounds
for bidx = 1:length(bounds)

%     if isequal(bounds(bidx).deriv,1); keyboard; end;

    % The times will be
    t = bounds(bidx).time - waypoints(bounds(bidx).seg).time;

    % Now, bounds(bidx).time is a vector of times when we wish to enforce
    % the constraint.  So, we willl generate a basis for each time and use
    % the basis block where we need it.  It will have dimensions of
    % length(t) by (n+1) where t is the time vector for this bound
    basis_block = basis(t, bounds(bidx).deriv, n, D);

    % Now scale it so the constraints are in the correct space (not
    % nondimensionalized)
    basis_block = basis_block./repmat(durations(bounds(bidx).seg).^tpow,[length(t), 1]);

    % idx indexes d, bgroup indexes the segment
    bgroup = bounds(bidx).seg;

    switch bounds(bidx).type

        case {'lb', 'ub'}

            % Loop through the dimensions
            for idx = 1:d

                % Only impose non-NaN constraints
                if ~isnan(bounds(bidx).arg(idx))

                    % Determine the rows which our basis_block will occupy
                    rows = (rows(end) + 1):(rows(end) + size(basis_block,1));

                    % Determine the column which the basis block will start
                    startidx = ((idx-1)+d*(bgroup-1))*(n+1)+1;

                    % Determine the sign of the bound
                    if isequal(bounds(bidx).type, 'ub')
                        s = 1;
                    elseif isequal(bounds(bidx).type, 'lb')
                        s = -1;
                    end

                    % The basis block will end n columns later
                    Aineq(rows, startidx:(startidx + n)) = s*basis_block;

                    % And save the bound in bineq
                    bineq(rows) = s*bounds(bidx).arg(idx);
                end
            end

        case '1norm'
            % This is in progress, but I don't wan't to waste too much time
            % on this right now

%             % NaN constraints also imply 0 weighting
%             bounds(bidx).arg(isnan(bounds(bidx).arg)) = 0;
%
%             % Which are the non-zero weightings?
%             d_logical_idx = ~isequal(0,bounds(bidx).arg);
%             nonzero_d = sum(d_logical_idx);
%
%             % Determine the rows which our basis_block will occupy
%             rows = (rows(end) + 1):(rows(end) + (2^nonzero_d)*size(basis_block,1));
%
%             % Determine the column which the basis blocks will start
%             idx = 1;
%             startidx = ((idx-1)+d*(bgroup-1))*(n+1)+1;
%
%             % Determine the sign of the bound
%             if isequal(bounds(bidx).type, 'ub')
%                 s = 1;
%             elseif isequal(bounds(bidx).type, 'lb')
%                 s = -1;
%             end
%
%             % The basis block will end n columns later
%             Aineq(rows, startidx:(startidx + n)) = s*basis_block;
%
%             % And save the bound in bineq
%             bineq(rows) = s*bounds(bidx).arg(idx);

        case 'infnorm'

    end
end
%% Construct the problem

problem.H = H;
problem.Aeq = [E; C];
problem.beq = [Ebeq; Cbeq];
problem.Aineq = Aineq;
problem.bineq = bineq;

%% Determine the solution

% We try a maxtrix inversion approach first, and use the QP solver if the
% matrix issues a singularity warning.
%
% min x'*H*x  subject to:  A*x <= b and Aeq*x = beq
if ~numerical

    temp = [2*problem.H, problem.Aeq';...
        problem.Aeq, zeros(size(problem.Aeq,1)')];

    % Set singularity warning to an error
    warning('error', 'MATLAB:singularMatrix');
    try
        % Analytic Solution
        x = temp \ [zeros(size(temp,1)-length(problem.beq),1); problem.beq];
        exitflag = true;
        
        % Now, extract the coefficients
        x = x(1:size(problem.H));
        
        vprintf('Solved analytically.\n');
        if cond(temp) > 10e8
            warning('Condition number = %2.2f\n', cond(temp));
        end
        
    catch
        % warning('MATLAB:singularMatrix');
        numerical = true;
        
        warning('Matrix inversion approach is nearly singular. Using numerical methods instead.');
    end
end

if numerical

    % If we have the cplex solvers in our path, use them.  Otherwise, we
    % will default to MATLAB's optimization toolbox and use quadprog.
    
    if false && exist('gurobi', 'file')
        vprintf('Solving using Gurobi...\n');
         
        clear model;
        model.Q = sparse(H);
        model.A = sparse([problem.Aeq; problem.Aineq]);
        model.rhs = [problem.beq; problem.bineq];
        
        model.sense = [...
            repmat('=', size(problem.Aeq, 1), 1); ...
            repmat('<', size(problem.Aineq, 1), 1)];
        
        % Bounds on x
        model.lb = - Inf(size(model.A, 2), 1);
        
        % Linear component
        model.obj = zeros(size(model.A,2), 1);
        
        % Params
        % params.NumericFocus = 1;            % ?
        % params.BarHomogeneous = 1;          % ?
        % params.BarConvTol = convergetol;    % convtol;
        params.BarIterLimit = inf;          % Maybe a time limit would be better
        params.Presolve = 2;                % Maximize presolve effort
        params.TimeLimit = 10;              % Not sure if this works
        params.OutputFlag = verbose;        % Display running output
        
        result = gurobi(model, params);
        vprintf('Gurobi status: %s, time: %2.3f seconds\n', result.status, result.runtime);
        
        x = [];
        if isfield(result, 'x')
            x = result.x;
        end
        
        exitflag = strcmp(result.status, 'OPTIMAL');

    elseif exist('cplexqp.p', 'file')
        vprintf('Solving using CPLEX...\n');
        
        problem.f = zeros(size(H,2),1);
        problem.options = cplexoptimset('cplex');
        % If primal obj and dual obj are this close, the solution is considered optimal
        problem.options.barrier.convergetol = convergetol;

        ticker2 = tic;
        [x, fval, exitflag, output] = cplexqp(problem); %#ok<ASGLU>
        temp = toc(ticker2);
        vprintf('CPLEX solve time: %2.3f seconds\n', temp);

    else
        vprintf('Solving using quadprog...\n');
        
        % Set up the problem
        problem.options = optimset('MaxIter',1500, 'Display','off', 'TolFun',convergetol);
        problem.solver = 'quadprog';

        % Numerical Solution
        ticker2 = tic;
        [x, fval, exitflag, output] = quadprog(problem); %#ok<ASGLU>
        temp = toc(ticker2);
        vprintf('QuadProg solve time: %2.3f seconds\n', temp);
    end

end

%% Package the solution
% The first dimension will index the polynomial coefficients
% The second dimension will index the dimension (e.g. x, y, z, psi, ...)
% The third dimension will index the segment
% The fourth dimension will index the derivative.
% So, traj.poly(:, b, c, d) will return the polynomial defining the b^th
% dimension, the c^th segment, and the (d-1)^th derivative.
traj.poly = zeros(n+1, d, N);
if ~isempty(x)
    traj.poly(:) = x;
else
    warning('No Solution found');
end

traj.durations = durations;
traj.keytimes = keytimes;

%% Generate the derivatives

for seg = 1:N
    for deriv = 1:4
        traj.poly(:,:,seg,deriv+1) = D{deriv}*traj.poly(:,:,seg, 1);
    end
end

end