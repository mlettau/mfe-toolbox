function [parameters, ll, Ht, VCV, scores] = rarch(data,p,q,type,method,startingVals,options)
% Estimation of RARCH(p,q) multivarate volatility model of Noureldin, Shephard and Sheppard
%
% USAGE:
%  [PARAMETERS] = rarch(DATA,P,Q)
%  [PARAMETERS,LL,HT,VCV,SCORES] = rarch(DATA,P,Q,TYPE,METHOD,STARTINGVALS,OPTIONS)
%
% INPUTS:
%   DATA         - A T by K matrix of zero mean residuals -OR-
%                    K by K by T array of covariance estimators (e.g. realized covariance)
%   P            - Positive, scalar integer representing the number of symmetric innovations
%   Q            - Non-negative, scalar integer representing the number of conditional covariance lags
%   TYPE         - [OPTIONAL] String, one of 'Scalar' (Default) ,'CP' (Common Persistence) or 'Diagonal'
%   METHOD       - [OPTIONAL] String, one of '2-stage' (Default) or 'Joint'
%   STARTINGVALS - [OPTIONAL] Vector of starting values to use.  See parameters and COMMENTS.
%   OPTIONS      - [OPTIONAL] Options to use in the model optimization (fmincon)
%
% OUTPUTS:
%   PARAMETERS   -
%   LL           - The log likelihood at the optimum
%   HT           - A [K K T] dimension matrix of conditional covariances
%   VCV          - A numParams^2 square matrix of robust parameter covariances (A^(-1)*B*A^(-1)/T)
%   SCORES       - A T by numParams matrix of individual scores
%
% COMMENTS:

% Copyright: Kevin Sheppard
% kevin.sheppard@economics.ox.ac.uk
% Revision: 1    Date: 3/27/2012

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Input Argument Checking
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Input Argument Checking
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if nargin<1
    error('3 to 8 inputs required.')
end
[T,k] = size(data);
if ndims(data)==3
    [k,~,T] = size(data);
end

switch nargin
    case 3
        type = 'Scalar';
        method = '2-stage';
        startingVals = [];
        options = [];
    case 4
        method = '2-stage';
        startingVals = [];
        options = [];
    case 5
        startingVals = [];
        options = [];
    case 6
        options = [];
    case 7
        % Nothing
    otherwise
        error('3 to 7 inputs required.')
end
if ndims(data)>3
    error('DATA must be either a T by K matrix or a K by K by T array.')
end
if T<=k
    error('DATA must be either a T by K matrix or a K by K by T array, and T must be larger than K.')
end

if p<1 || floor(p)~=p
    error('P must be a positive scalar.')
end
if q<=0 || floor(q)~=q
    error('Q must be a non-negative scalar.')
end

if strcmpi(type,'Scalar')
    type = 1;
elseif strcmpi(type,'CP')
    type = 2;
elseif strcmpi(type,'Diagonal')
    type = 3;
else
    error('TYPE must be ''Scalar'', ''CP'' or  ''Diagonal''.')
end

if strcmpi(method,'2-stage')
    isJoint = false;
elseif strcmpi(method,'Joint')
    isJoint = true;
else
    error('METHOD must be either ''2-stage'' or  ''Joint''.')
end

if isempty(options)
    options = optimset('fmincon');
    options.Display = 'iter';
    options.Diagnostics = 'on';
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Data Transformation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if ndims(data)==2
    temp = zeros(k,k,T);
    for i=1:T
        temp(:,:,i) = data(i,:)'*data(i,:);
    end
    data = temp;
end
C = mean(data,3);
stdData = zeros(k,k,T);
Cm12 = C^(-0.5);
for i=1:T
    stdData(:,:,i) = Cm12*data(:,:,i)*Cm12;
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Starting Values
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% FIXME : Need to improve this
% TODO  : Improve starting values
switch type
    case 1
        startingVals = sqrt([.05/p * ones(1,p) .93/q*ones(1,q)]);
    case 2
        startingVals = sqrt([.05/p * ones(1,k*p) .93]);
    case 3
        startingVals = sqrt([.05/p * ones(1,k*p) .93/q*ones(1,k*q)]);
end
startingVals = startingVals';
LB = -ones(size(startingVals));
UB = ones(size(startingVals));
w = .06*.94.^(0:ceil(sqrt(T)));
w = w/sum(w);
backCast = zeros(k);
for i=1:length(w)
    backCast = backCast + w(i)*stdData(:,:,i);
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Estimation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Use stdData and set C = eye(K)
parameters = fmincon(@rarch_likelihood,startingVals,[],[],[],[],LB,UB,@rarch_constraint,options,data,p,q,C,backCast,type,false,false);
[ll,~,Ht] = rarch_likelihood(parameters,data,p,q,C,backCast,type,false,false);
if isJoint
    CChol = chol2vec(chol(C)');
    startingValAll =[CChol;parameters];
    LBall = [-inf*ones(size(CChol));-ones(size(parameters))];
    UBall = abs(LBall);
    parameters = fmincon(@rarch_likelihood,startingValAll,[],[],[],[],LBall,UBall,@rarch_constraint,options,data,p,q,C,backCast,type,true,true);
    [ll,~,Ht] = rarch_likelihood(parameters,data,p,q,C,backCast,type,true,true);
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Inference
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
keyboard
k2 = k*(k+1)/2;
if isJoint
    C = parameters(1:k2);
    C = vec2chol(C);
    C = C*C';
    C = (C+C')/2;
    parameters = [vech(C);parameters(k2+1:length(parameters))];
    [VCV,~,~,scores] = robustvcv(@rarch_likelihood,parameters,0,data,p,q,C,backCast,type,true,false);
else
    scores1 = zeros(T,k2);
    for i=1:T
        scores1(i,:) = vech(data(:,:,i)-C)';
    end
    scores2 = gradient_2sided(@rarch_likelihood,parameters,data,p,q,C,backCast,type,true,true);
    scores = [scores1 scores2];
    B = covnw(scores,1.2*ceil(T^(0.25)));
    m = length(parameters);
    parameters = [vech(C);parameters];
    A1 = -eye(k2);
    A2 = hessian_2sided_nrows(@rarch_likelihood,parameters,m,data,p,q,C,backCast,type,true,false);
    A = [[A1 zeros(k2,m)];
          A2];
    Ainv = eye(length(A))\A;
    VCV = Ainv'*B*Ainv;
end
