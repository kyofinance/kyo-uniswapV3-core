import {UniswapV3Pool} from "./UniswapV3Pool.sol";
import {ICodeStorage} from "contracts/lib/ICodeStorage.sol";

contract UniswapV3PoolCreationCodeStorage is ICodeStorage {
    function getCreationCode() external view returns (bytes memory) {
        return type(UniswapV3Pool).creationCode;
    }
}
